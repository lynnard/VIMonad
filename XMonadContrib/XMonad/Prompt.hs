{-# LANGUAGE ExistentialQuantification #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.Prompt
-- Copyright   :  (C) 2007 Andrea Rossato
-- License     :  BSD3
--
-- Maintainer  :  Spencer Janssen <spencerjanssen@gmail.com>
-- Stability   :  unstable
-- Portability :  unportable
--
-- A module for writing graphical prompts for XMonad
--
-----------------------------------------------------------------------------

module XMonad.Prompt
    ( -- * Usage
      -- $usage
      mkXPrompt
    , mkXPromptWithReturn
    , mkXPromptWithHistoryAndReturn
    , readHistory
    , mkXPromptWithModes
    , def
    , amberXPConfig
    , defaultXPConfig
    , greenXPConfig
    , XPMode
    , XPType (..)
    , XPPosition (..)
    , XPConfig (..)
    , XPrompt (..)
    , XP
    , defaultXPKeymap, defaultXPKeymap'
    , emacsLikeXPKeymap, emacsLikeXPKeymap'
    , quit
    , killBefore, killAfter, startOfLine, endOfLine
    , pasteString, moveCursor
    , setInput, getInput
    , moveWord, moveWord', killWord, killWord', deleteString
    , moveHistory, setSuccess, setDone
    , Direction1D(..)
    , ComplFunction
    -- * X Utilities
    -- $xutils
    , mkUnmanagedWindow
    , fillDrawable
    -- * Other Utilities
    -- $utils
    , mkComplFunFromList
    , mkComplFunFromList'
    -- * @nextCompletion@ implementations
    , getNextOfLastWord
    , getNextCompletion
    -- * @highlightPredicate@ implementation
    , highlightMatching
    -- * List utilities
    , getLastWord
    , skipLastWord
    , splitInSubListsAt
    , breakAtSpace
    , uniqSort
    , historyCompletion
    , historyCompletionP
    , findWord
    , fillSpace
    -- * History filters
    , deleteAllDuplicates
    , deleteConsecutive
    , HistoryMatches
    , initMatches
    , historyUpMatching
    , historyDownMatching
    -- * Types
    , XPState
    , History
    -- search predicates
    , prefixSearchPredicate
    , infixSearchPredicate
    , repeatedGrep
    ) where

import           XMonad                       hiding (cleanMask, config)
import qualified XMonad                       as X (numberlockMask)
import qualified XMonad.StackSet              as W
import           XMonad.Util.Font
import           XMonad.Util.Types
import           XMonad.Util.XSelection       (getSelection)

import           Codec.Binary.UTF8.String     (decodeString,isUTF8Encoded)
import           Control.Applicative          ((<$>))
import           Control.Arrow                (first, (&&&), (***))
import           Control.Concurrent           (threadDelay)
import           Control.Exception.Extensible as E hiding (handle)
import           Control.Monad.State
import           Data.Bits
import           Data.Char                    (isSpace, toLower)
import           Data.IORef
import           Data.List
import qualified Data.Map                     as M
import           Data.Maybe                   (fromMaybe)
import           Data.Set                     (fromList, toList)
import           System.Directory             (getAppUserDataDirectory)
import           System.IO
import           System.Posix.Files
import           Text.Read (readMaybe)

-- $usage
-- For usage examples see "XMonad.Prompt.Shell",
-- "XMonad.Prompt.XMonad" or "XMonad.Prompt.Ssh"
--
-- TODO:
--
-- * scrolling the completions that don't fit in the window (?)

type XP = StateT XPState IO

data XPState =
    XPS { dpy                :: Display
        , rootw              :: !Window
        , win                :: !Window
        , screen             :: !Rectangle
        , complWin           :: Maybe Window
        , complWinDim        :: Maybe ComplWindowDim
        , complIndex         :: !(Int,Int)
        , showComplWin       :: Bool
        , operationMode      :: XPOperationMode
        , highlightedCompl   :: Maybe String
        , gcon               :: !GC
        , fontS              :: !XMonadFont
        , commandHistory     :: W.Stack String
        , offset             :: !Int
        , config             :: XPConfig
        , successful         :: Bool
        , numlockMask        :: KeyMask
        , done               :: Bool
        }

data XPConfig =
    XPC { font              :: String     -- ^ Font
        , bgColor           :: String     -- ^ Background color
        , fgColor           :: String     -- ^ Font color
        , fgHLight          :: String     -- ^ Font color of a highlighted completion entry
        , bgHLight          :: String     -- ^ Background color of a highlighted completion entry
        , borderColor       :: String     -- ^ Border color
        , promptBorderWidth :: !Dimension -- ^ Border width
        , position          :: XPPosition -- ^ Position: 'Top' or 'Bottom'
        , alwaysHighlight   :: !Bool      -- ^ Always highlight an item, overriden to True with multiple modes. This implies having *one* column of autocompletions only.
        , height            :: !Dimension -- ^ Window height
        , maxComplRows      :: Maybe Dimension
                                          -- ^ Just x: maximum number of rows to show in completion window
        , historySize       :: !Int       -- ^ The number of history entries to be saved
        , historyFilter     :: [String] -> [String]
                                         -- ^ a filter to determine which
                                         -- history entries to remember
        , promptKeymap      :: M.Map (KeyMask,KeySym) (XP ())
                                         -- ^ Mapping from key combinations to actions
        , completionKey     :: KeySym     -- ^ Key that should trigger completion
        , reverseCompletionKey :: KeySym -- ^ Key that when pressed with the completion key reverse the completion
        , changeModeKey     :: KeySym     -- ^ Key to change mode (when the prompt has multiple modes)
        , defaultText       :: String     -- ^ The text by default in the prompt line
        , autoComplete      :: Maybe Int  -- ^ Just x: if only one completion remains, auto-select it,
        , showCompletionOnTab :: Bool     -- ^ Only show list of completions when Tab was pressed
                                          --   and delay by x microseconds
        , searchPredicate   :: String -> String -> Bool
                                          -- ^ Given the typed string and a possible
                                          --   completion, is the completion valid?
        -- decide how to print ansi color sequence; (basically it should be a color table sort of stuff)
        , ansiToHex :: Int -> String 
        }

data XPType = forall p . XPrompt p => XPT p
type ComplFunction = String -> IO [String]
type XPMode = XPType
data XPOperationMode = XPSingleMode ComplFunction XPType | XPMultipleModes (W.Stack XPType)

instance Show XPType where
    show (XPT p) = showXPrompt p

instance XPrompt XPType where
    showXPrompt                 = show
    nextCompletion      (XPT t) = nextCompletion      t
    commandToComplete   (XPT t) = commandToComplete   t
    completionToCommand (XPT t) = completionToCommand t
    completionFunction  (XPT t) = completionFunction  t
    modeAction          (XPT t) = modeAction          t
    highlightPredicate  (XPT t) = highlightPredicate  t

-- | The class prompt types must be an instance of. In order to
-- create a prompt you need to create a data type, without parameters,
-- and make it an instance of this class, by implementing a simple
-- method, 'showXPrompt', which will be used to print the string to be
-- displayed in the command line window.
--
-- This is an example of a XPrompt instance definition:
--
-- >     instance XPrompt Shell where
-- >          showXPrompt Shell = "Run: "
class XPrompt t where

    -- | This method is used to print the string to be
    -- displayed in the command line window.
    showXPrompt :: t -> String

    -- | This method is used to generate the next completion to be
    -- printed in the command line when tab is pressed, given the
    -- string presently in the command line and the list of
    -- completion.
    -- This function is not used when in multiple modes (because alwaysHighlight in XPConfig is True)
    -- An additional argument tells the prompt to shift the cursor to the given offset
    nextCompletion :: t -> (String, Int) -> [String] -> (String, Int)
    nextCompletion = getNextOfLastWord

    -- | This method is used to generate the string to be passed to
    -- the completion function.
    commandToComplete :: t -> String -> String
    commandToComplete _ = getLastWord

    -- | This method is used to process each completion in order to
    -- generate the string that will be compared with the command
    -- presently displayed in the command line. If the prompt is using
    -- 'getNextOfLastWord' for implementing 'nextCompletion' (the
    -- default implementation), this method is also used to generate,
    -- from the returned completion, the string that will form the
    -- next command line when tab is pressed.
    completionToCommand :: t -> String -> String
    completionToCommand _ c = c

    -- | When the prompt has multiple modes, this is the function
    -- used to generate the autocompletion list.
    -- The argument passed to this function is given by `commandToComplete`
    -- The default implementation shows an error message.
    completionFunction :: t -> ComplFunction
    completionFunction t = \_ -> return ["Completions for " ++ (showXPrompt t) ++ " could not be loaded"]

    -- | When the prompt has multiple modes (created with mkXPromptWithModes), this function is called
    -- when the user picks an item from the autocompletion list.
    -- The first argument is the prompt (or mode) on which the item was picked
    -- The first string argument is the autocompleted item's text.
    -- The second string argument is the query made by the user (written in the prompt's buffer).
    -- See XMonad/Actions/Launcher.hs for a usage example.
    modeAction :: t -> String -> String -> X ()
    modeAction _ _ _ = return ()

    -- | Given the completion item and the command string, whether it should be highlighted
    highlightPredicate :: t -> String -> (String, Int) -> Bool
    highlightPredicate = highlightMatching 


--- a highlightPredicate implementation (default)
highlightMatching t item (buffer,_) = completionToCommand t item == commandToComplete t buffer

data XPPosition = Top
                | Bottom
                  deriving (Show,Read)

amberXPConfig, defaultXPConfig, greenXPConfig :: XPConfig

instance Default XPConfig where
  def =
    XPC { font              = "-misc-fixed-*-*-*-*-12-*-*-*-*-*-*-*"
        , bgColor           = "grey22"
        , fgColor           = "grey80"
        , fgHLight          = "black"
        , bgHLight          = "grey"
        , borderColor       = "white"
        , promptBorderWidth = 1
        , promptKeymap      = defaultXPKeymap
        , completionKey     = xK_Tab
        , reverseCompletionKey = 65056
        , changeModeKey     = xK_grave
        , position          = Bottom
        , height            = 18
        , maxComplRows      = Nothing
        , historySize       = 256
        , historyFilter     = id
        , defaultText       = []
        , autoComplete      = Nothing
        , showCompletionOnTab = False
        , searchPredicate   = isPrefixOf
        , alwaysHighlight   = False
        , ansiToHex = \c -> maybe "#000000" snd $ find ((==c) . fst) [
                -- Primary 3-bit (8 colors). Unique representation!
                (0,  "#000000"),
                (1,  "#800000"),
                (2,  "#008000"),
                (3,  "#808000"),
                (4,  "#000080"),
                (5,  "#800080"),
                (6,  "#008080"),
                (7,  "#c0c0c0"),
             
                -- Equivalent bright# versions of original 8 colors.
                (8,  "#808080"),
                (9,  "#ff0000"),
                (10,  "#00ff00"),
                (11,  "#ffff00"),
                (12,  "#0000ff"),
                (13,  "#ff00ff"),
                (14,  "#00ffff"),
                (15,  "#ffffff"),
             
                -- Strictly ascending.
                (16,  "#000000"),
                (17,  "#00005f"),
                (18,  "#000087"),
                (19,  "#0000af"),
                (20,  "#0000d7"),
                (21,  "#0000ff"),
                (22,  "#005f00"),
                (23,  "#005f5f"),
                (24,  "#005f87"),
                (25,  "#005faf"),
                (26,  "#005fd7"),
                (27,  "#005fff"),
                (28,  "#008700"),
                (29,  "#00875f"),
                (30,  "#008787"),
                (31,  "#0087af"),
                (32,  "#0087d7"),
                (33,  "#0087ff"),
                (34,  "#00af00"),
                (35,  "#00af5f"),
                (36,  "#00af87"),
                (37,  "#00afaf"),
                (38,  "#00afd7"),
                (39,  "#00afff"),
                (40,  "#00d700"),
                (41,  "#00d75f"),
                (42,  "#00d787"),
                (43,  "#00d7af"),
                (44,  "#00d7d7"),
                (45,  "#00d7ff"),
                (46,  "#00ff00"),
                (47,  "#00ff5f"),
                (48,  "#00ff87"),
                (49,  "#00ffaf"),
                (50,  "#00ffd7"),
                (51,  "#00ffff"),
                (52,  "#5f0000"),
                (53,  "#5f005f"),
                (54,  "#5f0087"),
                (55,  "#5f00af"),
                (56,  "#5f00d7"),
                (57,  "#5f00ff"),
                (58,  "#5f5f00"),
                (59,  "#5f5f5f"),
                (60,  "#5f5f87"),
                (61,  "#5f5faf"),
                (62,  "#5f5fd7"),
                (63,  "#5f5fff"),
                (64,  "#5f8700"),
                (65,  "#5f875f"),
                (66,  "#5f8787"),
                (67,  "#5f87af"),
                (68,  "#5f87d7"),
                (69,  "#5f87ff"),
                (70,  "#5faf00"),
                (71,  "#5faf5f"),
                (72,  "#5faf87"),
                (73,  "#5fafaf"),
                (74,  "#5fafd7"),
                (75,  "#5fafff"),
                (76,  "#5fd700"),
                (77,  "#5fd75f"),
                (78,  "#5fd787"),
                (79,  "#5fd7af"),
                (80,  "#5fd7d7"),
                (81,  "#5fd7ff"),
                (82,  "#5fff00"),
                (83,  "#5fff5f"),
                (84,  "#5fff87"),
                (85,  "#5fffaf"),
                (86,  "#5fffd7"),
                (87,  "#5fffff"),
                (88,  "#870000"),
                (89,  "#87005f"),
                (90,  "#870087"),
                (91,  "#8700af"),
                (92,  "#8700d7"),
                (93,  "#8700ff"),
                (94,  "#875f00"),
                (95,  "#875f5f"),
                (96,  "#875f87"),
                (97,  "#875faf"),
                (98,  "#875fd7"),
                (99,  "#875fff"),
                (100, "#878700"),
                (101, "#87875f"),
                (102, "#878787"),
                (103, "#8787af"),
                (104, "#8787d7"),
                (105, "#8787ff"),
                (106, "#87af00"),
                (107, "#87af5f"),
                (108, "#87af87"),
                (109, "#87afaf"),
                (110, "#87afd7"),
                (111, "#87afff"),
                (112, "#87d700"),
                (113, "#87d75f"),
                (114, "#87d787"),
                (115, "#87d7af"),
                (116, "#87d7d7"),
                (117, "#87d7ff"),
                (118, "#87ff00"),
                (119, "#87ff5f"),
                (120, "#87ff87"),
                (121, "#87ffaf"),
                (122, "#87ffd7"),
                (123, "#87ffff"),
                (124, "#af0000"),
                (125, "#af005f"),
                (126, "#af0087"),
                (127, "#af00af"),
                (128, "#af00d7"),
                (129, "#af00ff"),
                (130, "#af5f00"),
                (131, "#af5f5f"),
                (132, "#af5f87"),
                (133, "#af5faf"),
                (134, "#af5fd7"),
                (135, "#af5fff"),
                (136, "#af8700"),
                (137, "#af875f"),
                (138, "#af8787"),
                (139, "#af87af"),
                (140, "#af87d7"),
                (141, "#af87ff"),
                (142, "#afaf00"),
                (143, "#afaf5f"),
                (144, "#afaf87"),
                (145, "#afafaf"),
                (146, "#afafd7"),
                (147, "#afafff"),
                (148, "#afd700"),
                (149, "#afd75f"),
                (150, "#afd787"),
                (151, "#afd7af"),
                (152, "#afd7d7"),
                (153, "#afd7ff"),
                (154, "#afff00"),
                (155, "#afff5f"),
                (156, "#afff87"),
                (157, "#afffaf"),
                (158, "#afffd7"),
                (159, "#afffff"),
                (160, "#d70000"),
                (161, "#d7005f"),
                (162, "#d70087"),
                (163, "#d700af"),
                (164, "#d700d7"),
                (165, "#d700ff"),
                (166, "#d75f00"),
                (167, "#d75f5f"),
                (168, "#d75f87"),
                (169, "#d75faf"),
                (170, "#d75fd7"),
                (171, "#d75fff"),
                (172, "#d78700"),
                (173, "#d7875f"),
                (174, "#d78787"),
                (175, "#d787af"),
                (176, "#d787d7"),
                (177, "#d787ff"),
                (178, "#d7af00"),
                (179, "#d7af5f"),
                (180, "#d7af87"),
                (181, "#d7afaf"),
                (182, "#d7afd7"),
                (183, "#d7afff"),
                (184, "#d7d700"),
                (185, "#d7d75f"),
                (186, "#d7d787"),
                (187, "#d7d7af"),
                (188, "#d7d7d7"),
                (189, "#d7d7ff"),
                (190, "#d7ff00"),
                (191, "#d7ff5f"),
                (192, "#d7ff87"),
                (193, "#d7ffaf"),
                (194, "#d7ffd7"),
                (195, "#d7ffff"),
                (196, "#ff0000"),
                (197, "#ff005f"),
                (198, "#ff0087"),
                (199, "#ff00af"),
                (200, "#ff00d7"),
                (201, "#ff00ff"),
                (202, "#ff5f00"),
                (203, "#ff5f5f"),
                (204, "#ff5f87"),
                (205, "#ff5faf"),
                (206, "#ff5fd7"),
                (207, "#ff5fff"),
                (208, "#ff8700"),
                (209, "#ff875f"),
                (210, "#ff8787"),
                (211, "#ff87af"),
                (212, "#ff87d7"),
                (213, "#ff87ff"),
                (214, "#ffaf00"),
                (215, "#ffaf5f"),
                (216, "#ffaf87"),
                (217, "#ffafaf"),
                (218, "#ffafd7"),
                (219, "#ffafff"),
                (220, "#ffd700"),
                (221, "#ffd75f"),
                (222, "#ffd787"),
                (223, "#ffd7af"),
                (224, "#ffd7d7"),
                (225, "#ffd7ff"),
                (226, "#ffff00"),
                (227, "#ffff5f"),
                (228, "#ffff87"),
                (229, "#ffffaf"),
                (230, "#ffffd7"),
                (231, "#ffffff"),
             
                -- Gray-scale range.
                (232, "#080808"),
                (233, "#121212"),
                (234, "#1c1c1c"),
                (235, "#262626"),
                (236, "#303030"),
                (237, "#3a3a3a"),
                (238, "#444444"),
                (239, "#4e4e4e"),
                (240, "#585858"),
                (241, "#626262"),
                (242, "#6c6c6c"),
                (243, "#767676"),
                (244, "#808080"),
                (245, "#8a8a8a"),
                (246, "#949494"),
                (247, "#9e9e9e"),
                (248, "#a8a8a8"),
                (249, "#b2b2b2"),
                (250, "#bcbcbc"),
                (251, "#c6c6c6"),
                (252, "#d0d0d0"),
                (253, "#dadada"),
                (254, "#e4e4e4"),
                (255, "#eeeeee") 
            ]
        }
{-# DEPRECATED defaultXPConfig "Use def (from Data.Default, and re-exported from XMonad.Prompt) instead." #-}
defaultXPConfig = def
greenXPConfig = def { fgColor = "green", bgColor = "black", promptBorderWidth = 0 }
amberXPConfig = def { fgColor = "#ca8f2d", bgColor = "black", fgHLight = "#eaaf4c" }

initState :: Display -> Window -> Window -> Rectangle -> XPOperationMode
          -> GC -> XMonadFont -> [String] -> XPConfig -> KeyMask -> XPState
initState d rw w s opMode gc fonts h c nm =
    XPS { dpy                = d
        , rootw              = rw
        , win                = w
        , screen             = s
        , complWin           = Nothing
        , complWinDim        = Nothing
        , showComplWin       = not (showCompletionOnTab c)
        , operationMode      = opMode
        , highlightedCompl   = Nothing
        , gcon               = gc
        , fontS              = fonts
        , commandHistory     = W.Stack { W.focus = defaultText c
                                       , W.up    = []
                                       , W.down  = h }
        , complIndex         = (0,0) --(column index, row index), used when `alwaysHighlight` in XPConfig is True
        , offset             = length (defaultText c)
        , config             = c
        , successful         = False
        , done               = False
        , numlockMask        = nm
        }

-- Returns the current XPType
currentXPMode :: XPState -> XPType
currentXPMode st = case operationMode st of
  XPMultipleModes modes -> W.focus modes
  XPSingleMode _ xptype -> xptype

-- When in multiple modes, this function sets the next mode
-- in the list of modes as active
setNextMode :: XPState -> XPState
setNextMode st = case operationMode st of
  XPMultipleModes modes -> case W.down modes of
    [] -> st -- there is no next mode, return same state
    (m:ms) -> let
      currentMode = W.focus modes
      in st { operationMode = XPMultipleModes W.Stack { W.up = [], W.focus = m, W.down = ms ++ [currentMode]}} --set next and move previous current mode to the of the stack
  _ -> st --nothing to do, the prompt's operation has only one mode

-- Returns the highlighted item
highlightedItem :: XPState -> [String] -> Maybe String
highlightedItem st' completions = case complWinDim st' of
  Nothing -> Nothing -- when there isn't any compl win, we can't say how many cols,rows there are
  Just winDim ->
    let
      (_,_,_,_,xx,yy) = winDim
      complMatrix = splitInSubListsAt (length yy) (take (length xx * length yy) completions)
      (col_index,row_index) = (complIndex st')
    in case completions of
      [] -> Nothing
      _ -> Just $ complMatrix !! col_index !! row_index

-- this would be much easier with functional references
command :: XPState -> String
command = W.focus . commandHistory

setCommand :: String -> XPState -> XPState
setCommand xs s = s { commandHistory = (commandHistory s) { W.focus = xs }}

setHighlightedCompl :: Maybe String -> XPState -> XPState
setHighlightedCompl hc st = st { highlightedCompl = hc}

-- | Sets the input string to the given value.
setInput :: String -> XP ()
setInput = modify . setCommand

-- | Returns the current input string. Intented for use in custom keymaps
-- where the 'get' or similar can't be used to retrieve it.
getInput :: XP String
getInput = gets command

mkXPromptWithReturn :: XPrompt p => p -> XPConfig -> ComplFunction -> (String -> X a)  -> X (Maybe a)
mkXPromptWithReturn t conf compl action = (io readHistory) >>= mkXPromptWithHistoryAndReturn t conf compl action

-- | Same as 'mkXPrompt', except that the action function can have
--   type @String -> X a@, for any @a@, and the final action returned
--   by 'mkXPromptWithReturn' will have type @X (Maybe a)@.  @Nothing@
--   is yielded if the user cancels the prompt (by e.g. hitting Esc or
--   Ctrl-G).  For an example of use, see the 'XMonad.Prompt.Input'
--   module.
mkXPromptWithHistoryAndReturn :: XPrompt p => p -> XPConfig -> ComplFunction -> (String -> X a) -> History  -> X (Maybe a)
mkXPromptWithHistoryAndReturn t conf compl action hist = do
  XConf { display = d, theRoot = rw } <- ask
  s    <- gets $ screenRect . W.screenDetail . W.current . windowset
  w    <- io $ createWin d rw conf s
  io $ selectInput d w $ exposureMask .|. keyPressMask
  gc <- io $ createGC d w
  io $ setGraphicsExposures d gc False
  fs <- initXMF (font conf)
  numlock <- gets $ X.numberlockMask
  let hs = fromMaybe [] $ M.lookup (showXPrompt t) hist
      om = (XPSingleMode compl (XPT t)) --operation mode
      st = initState d rw w s om gc fs hs conf numlock
  st' <- io $ execStateT runXP st

  releaseXMF fs
  io $ freeGC d gc
  if successful st' then do
    let
      prune = take (historySize conf)

    io $ writeHistory $ M.insertWith
      (\xs ys -> prune . historyFilter conf $ xs ++ ys)
      (showXPrompt t)
      (prune $ historyFilter conf [command st'])
      hist
                                -- we need to apply historyFilter before as well, since
                                -- otherwise the filter would not be applied if
                                -- there is no history
      --When alwaysHighlight is True, autocompletion is handled with indexes.
      --When it is false, it is handled depending on the prompt buffer's value
    let selectedCompletion = case alwaysHighlight (config st') of
          False -> command st'
          True -> fromMaybe (command st') $ highlightedCompl st' -- 
    Just <$> action selectedCompletion
    else return Nothing

-- | Creates a prompt given:
--
-- * a prompt type, instance of the 'XPrompt' class.
--
-- * a prompt configuration ('def' can be used as a starting point)
--
-- * a completion function ('mkComplFunFromList' can be used to
-- create a completions function given a list of possible completions)
--
-- * an action to be run: the action must take a string and return 'XMonad.X' ()
mkXPrompt :: XPrompt p => p -> XPConfig -> ComplFunction -> (String -> X ()) -> X ()
mkXPrompt t conf compl action = mkXPromptWithReturn t conf compl action >> return ()

-- | Creates a prompt with multiple modes given:
--
-- * A non-empty list of modes
-- * A prompt configuration
--
-- The created prompt allows to switch between modes with `changeModeKey` in `conf`. The modes are
-- instances of XPrompt. See XMonad.Actions.Launcher for more details
--
-- The argument supplied to the action to execute is always the current highlighted item,
-- that means that this prompt overrides the value `alwaysHighlight` for its configuration to True.
mkXPromptWithModes :: [XPType] -> XPConfig -> X ()
mkXPromptWithModes modes conf = do
  XConf { display = d, theRoot = rw } <- ask
  s    <- gets $ screenRect . W.screenDetail . W.current . windowset
  hist <- io readHistory
  w    <- io $ createWin d rw conf s
  io $ selectInput d w $ exposureMask .|. keyPressMask
  gc <- io $ createGC d w
  io $ setGraphicsExposures d gc False
  fs <- initXMF (font conf)
  numlock <- gets $ X.numberlockMask
  let
    defaultMode = head modes
    hs = fromMaybe [] $ M.lookup (showXPrompt defaultMode) hist
    modeStack = W.Stack{ W.focus = defaultMode --current mode
                       , W.up = []
                       , W.down = tail modes --other modes
                       }
    st = initState d rw w s (XPMultipleModes modeStack) gc fs hs conf { alwaysHighlight = True} numlock
  st' <- io $ execStateT runXP st

  releaseXMF fs
  io $ freeGC d gc

  if successful st' then do
    let
      prune = take (historySize conf)

      -- insert into history the buffers value
    io $ writeHistory $ M.insertWith
      (\xs ys -> prune . historyFilter conf $ xs ++ ys)
      (showXPrompt defaultMode)
      (prune $ historyFilter conf [command st'])
      hist

    case operationMode st' of
      XPMultipleModes ms -> let
        action = modeAction $ W.focus ms
        in action (command st') $ (fromMaybe "" $ highlightedCompl st')
      _ -> error "The impossible occurred: This prompt runs with multiple modes but they could not be found." --we are creating a prompt with multiple modes, so its operationMode should have been constructed with XPMultipleMode
    else
      return ()


runXP :: XP ()
runXP = do
  (d,w) <- gets (dpy &&& win)
  status <- io $ grabKeyboard d w True grabModeAsync grabModeAsync currentTime
  when (status == grabSuccess) $ do
          updateWindows
          eventLoop handle
          io $ ungrabKeyboard d currentTime
  io $ destroyWindow d w
  destroyComplWin
  io $ sync d False

type KeyStroke = (KeySym, String)

eventLoop :: (KeyStroke -> Event -> XP ()) -> XP ()
eventLoop action = do
  d <- gets dpy
  (keysym,string,event) <- io $
            allocaXEvent $ \e -> do
              maskEvent d (exposureMask .|. keyPressMask) e
              ev <- getEvent e
              (ks,s) <- if ev_event_type ev == keyPress
                        then lookupString $ asKeyEvent e
                        else return (Nothing, "")
              return (ks,s,ev)
  action (fromMaybe xK_VoidSymbol keysym,string) event
  gets done >>= flip unless (eventLoop handle)

-- | Removes numlock and capslock from a keymask.
-- Duplicate of cleanMask from core, but in the
-- XP monad instead of X.
cleanMask :: KeyMask -> XP KeyMask
cleanMask msk = do
  numlock <- gets numlockMask
  let highMasks = 1 `shiftL` 12 - 1
  return (complement (numlock .|. lockMask) .&. msk .&. highMasks)

-- Main event handler
handle :: KeyStroke -> Event -> XP ()
handle ks@(sym,_) e@(KeyEvent {ev_event_type = t, ev_state = m}) = do
  complKey <- gets $ completionKey . config
  chgModeKey <- gets $ changeModeKey . config
  reverseComplKey <- gets $ reverseCompletionKey . config
  c <- getCompletions
  when (length c > 1) $ modify (\s -> s { showComplWin = True })
  if complKey == sym || reverseComplKey == sym
     then completionHandle c ks e
     else if (sym == chgModeKey) then
           do
             modify setNextMode
             updateWindows
          else when (t == keyPress) $ keyPressHandle m ks
handle _ (ExposeEvent {ev_window = w}) = do
  st <- get
  when (win st == w) updateWindows
handle _  _ = return ()

-- completion event handler
completionHandle ::  [String] -> KeyStroke -> Event -> XP ()
completionHandle c ks@(sym,_) (KeyEvent { ev_event_type = t, ev_state = m }) = do
  complKey <- gets $ completionKey . config
  -- get the mask we are talking about
  reverseComplKey <- gets $ reverseCompletionKey . config
  alwaysHlight <- gets $ alwaysHighlight . config
  case t of
    keyPress | sym `elem` [complKey, reverseComplKey] ->
          do
            st <- get
            let updateState l = case alwaysHlight of
                  -- modify the buffer's value
                  False -> let (newCommand, os) = nextCompletion (currentXPMode st) (command st, offset st) l
                           in modify $ \s -> setCommand newCommand $ s { offset = os, highlightedCompl = Just newCommand}
                  --TODO: Scroll or paginate results
                  True -> let complIndex' = nextComplIndex st (length l)
                              highlightedCompl' = highlightedItem st { complIndex = complIndex'} c
                          in modify $ \s -> setHighlightedCompl highlightedCompl' $ s { complIndex = complIndex' }
                updateWins l = redrawWindows l >> eventLoop (completionHandle l)
                updateStateWithDir l = updateState $ if sym == reverseComplKey then reverse l else l
            case c of
              []  -> updateWindows   >> eventLoop handle
              [x] -> updateStateWithDir [x] >> getCompletions >>= updateWins
              l   -> updateStateWithDir l   >> updateWins l
              -- dirty hack below (the reason for this: the shift key is first sent and then shift+tab becomes backtab; this sounds stupid but is still how it works. so we have to eliminate that case as well)
             | sym == xK_Shift_L -> eventLoop (completionHandle c)
    keyRelease | sym `elem` [complKey, reverseComplKey] -> eventLoop (completionHandle c)
    _ -> keyPressHandle m ks -- some other key, handle it normally
-- some other event: go back to main loop
completionHandle _ k e = handle k e

--Receives an state of the prompt, the size of the autocompletion list and returns the column,row
--which should be highlighted next
nextComplIndex :: XPState -> Int -> (Int,Int)
nextComplIndex st nitems = case complWinDim st of
  Nothing -> (0,0) --no window dims (just destroyed or not created)
  Just (_,_,_,_,_,yy) -> let
    (ncols,nrows) = (nitems `div` length yy + if (nitems `mod` length yy > 0) then 1 else 0, length yy)
    (currentcol,currentrow) = complIndex st
    in if (currentcol + 1 >= ncols) then --hlight is in the last column
         if (currentrow + 1 < nrows ) then --hlight is still not at the last row
           (currentcol, currentrow + 1)
         else
           (0,0)
       else if(currentrow + 1 < nrows) then --hlight not at the last row
              (currentcol, currentrow + 1)
            else
              (currentcol + 1, 0)

tryAutoComplete :: XP Bool
tryAutoComplete = do
    ac <- gets (autoComplete . config)
    case ac of
        Just d -> do cs <- getCompletions
                     case cs of
                         [c] -> runCompleted c d >> return True
                         _   -> return False
        Nothing    -> return False
  where runCompleted cmd delay = do
            st <- get
            let (new_command, _) = nextCompletion (currentXPMode st) (command st, offset st) [cmd]
            modify $ setCommand "autocompleting..."
            updateWindows
            io $ threadDelay delay
            modify $ setCommand new_command
            return True

-- KeyPresses

-- | Default key bindings for prompts.  Click on the \"Source\" link
--   to the right to see the complete list.  See also 'defaultXPKeymap''.
defaultXPKeymap :: M.Map (KeyMask,KeySym) (XP ())
defaultXPKeymap = defaultXPKeymap' isSpace

-- | A variant of 'defaultXPKeymap' which lets you specify a custom
--   predicate for identifying non-word characters, which affects all
--   the word-oriented commands (move\/kill word).  The default is
--   'isSpace'.  For example, by default a path like @foo\/bar\/baz@
--   would be considered as a single word.  You could use a predicate
--   like @(\\c -> isSpace c || c == \'\/\')@ to move through or
--   delete components of the path one at a time.
defaultXPKeymap' :: (Char -> Bool) -> M.Map (KeyMask,KeySym) (XP ())
defaultXPKeymap' p = M.fromList $
  map (first $ (,) controlMask) -- control + <key>
  [ (xK_u, killBefore)
  , (xK_k, killAfter)
  , (xK_a, startOfLine)
  , (xK_e, endOfLine)
  , (xK_y, pasteString)
  , (xK_Right, moveWord' p Next)
  , (xK_Left, moveWord' p Prev)
  , (xK_Delete, killWord' p Next)
  , (xK_BackSpace, killWord' p Prev)
  , (xK_w, killWord' p Prev)
  , (xK_g, quit)
  , (xK_bracketleft, quit)
  ] ++
  map (first $ (,) 0)
  [ (xK_Return, setSuccess True >> setDone True)
  , (xK_KP_Enter, setSuccess True >> setDone True)
  , (xK_BackSpace, deleteString Prev)
  , (xK_Delete, deleteString Next)
  , (xK_Left, moveCursor Prev)
  , (xK_Right, moveCursor Next)
  , (xK_Home, startOfLine)
  , (xK_End, endOfLine)
  , (xK_Down, moveHistory W.focusUp')
  , (xK_Up, moveHistory W.focusDown')
  , (xK_Escape, quit)
  ]

-- | A keymap with many emacs-like key bindings.  Click on the
--   \"Source\" link to the right to see the complete list.
--   See also 'emacsLikeXPKeymap''.
emacsLikeXPKeymap :: HistoryMatches -> M.Map (KeyMask,KeySym) (XP ())
emacsLikeXPKeymap ref = emacsLikeXPKeymap' isSpace ref

-- | A variant of 'emacsLikeXPKeymap' which lets you specify a custom
--   predicate for identifying non-word characters, which affects all
--   the word-oriented commands (move\/kill word).  The default is
--   'isSpace'.  For example, by default a path like @foo\/bar\/baz@
--   would be considered as a single word.  You could use a predicate
--   like @(\\c -> isSpace c || c == \'\/\')@ to move through or
--   delete components of the path one at a time.
emacsLikeXPKeymap' :: (Char -> Bool) -> HistoryMatches -> M.Map (KeyMask,KeySym) (XP ())
{-emacsLikeXPKeymap' p = M.fromList $-}
  {-map (first $ (,) controlMask) -- control + <key>-}
  {-[ (xK_z, killBefore) --kill line backwards-}
  {-, (xK_k, killAfter) -- kill line fowards-}
  {-, (xK_a, startOfLine) --move to the beginning of the line-}
  {-, (xK_e, endOfLine) -- move to the end of the line-}
  {-, (xK_d, deleteString Next) -- delete a character foward-}
  {-, (xK_b, moveCursor Prev) -- move cursor forward-}
  {-, (xK_f, moveCursor Next) -- move cursor backward-}
  {-, (xK_BackSpace, killWord' p Prev) -- kill the previous word-}
  {-, (xK_y, pasteString)-}
  {-, (xK_g, quit)-}
  {-, (xK_bracketleft, quit)-}
  {-] ++-}
  {-map (first $ (,) mod1Mask) -- meta key + <key>-}
  {-[ (xK_BackSpace, killWord' p Prev)-}
  {-, (xK_f, moveWord' p Next) -- move a word forward-}
  {-, (xK_b, moveWord' p Prev) -- move a word backward-}
  {-, (xK_d, killWord' p Next) -- kill the next word-}
  {-, (xK_n, moveHistory W.focusUp')-}
  {-, (xK_p, moveHistory W.focusDown')-}
  {-]-}
  {-++-}
  {-map (first $ (,) 0) -- <key>-}
  {-[ (xK_Return, setSuccess True >> setDone True)-}
  {-, (xK_KP_Enter, setSuccess True >> setDone True)-}
  {-, (xK_BackSpace, deleteString Prev)-}
  {-, (xK_Delete, deleteString Next)-}
  {-, (xK_Left, moveCursor Prev)-}
  {-, (xK_Right, moveCursor Next)-}
  {-, (xK_Home, startOfLine)-}
  {-, (xK_End, endOfLine)-}
  {-, (xK_Down, moveHistory W.focusUp')-}
  {-, (xK_Up, moveHistory W.focusDown')-}
  {-, (xK_Escape, quit)-}
  {-]-}
emacsLikeXPKeymap' p ref = M.fromList $
  map (first $ (,) controlMask) -- control + <key>
  [ (xK_z, killBefore) --kill line backwards
  , (xK_g, quit)
  , (xK_bracketleft, quit)
  , (xK_BackSpace, killWord' p Prev) -- kill the previous word
  -- navigation
  , (xK_n, historyDownMatchingP prefixSearchPredicate 0 ref)
  , (xK_p, historyUpMatchingP prefixSearchPredicate 0 ref)
  , (xK_semicolon, historyDownMatchingP repeatedGrep 1 ref)
  , (xK_comma, historyUpMatchingP repeatedGrep 1 ref)
  , (xK_b, moveCursor Prev) -- move cursor forward
  , (xK_f, moveCursor Next) -- move cursor backward
  -- some vim bindings
  , (xK_w, killWord' p Prev) -- kill the previous word
  , (xK_u, killBefore)
  , (xK_h, deleteString Prev)
  -- other useful bindings borrowed from ranger
  , (xK_k, killAfter)
  , (xK_y, pasteString)
  , (xK_a, startOfLine) --move to the beginning of the line
  , (xK_e, endOfLine) -- move to the end of the line
  , (xK_d, deleteString Next) -- delete a character foward
  ] ++
  map (first $ (,) mod1Mask) -- meta key + <key>
  [ (xK_BackSpace, killWord' p Prev)
  , (xK_f, moveWord' p Next) -- move a word forward
  , (xK_b, moveWord' p Prev) -- move a word backward
  , (xK_d, killWord' p Next) -- kill the next word
  ]
  ++
  map (first $ (,) 0) -- <key>
  [ (xK_Return, setSuccess True >> setDone True)
  , (xK_KP_Enter, setSuccess True >> setDone True)
  , (xK_BackSpace, deleteString Prev)
  , (xK_Delete, deleteString Next)
  , (xK_Left, moveCursor Prev)
  , (xK_Right, moveCursor Next)
  , (xK_Home, startOfLine)
  , (xK_End, endOfLine)
  , (xK_Down, moveHistory W.focusUp')
  , (xK_Up, moveHistory W.focusDown')
  , (xK_Escape, quit)
  ]

keyPressHandle :: KeyMask -> KeyStroke -> XP ()
keyPressHandle m (ks,str) = do
  km <- gets (promptKeymap . config)
  kmask <- cleanMask m -- mask is defined in ghc7
  case M.lookup (kmask,ks) km of
    Just action -> action >> updateWindows
    Nothing -> case str of
                 "" -> eventLoop handle
                 _ -> when (kmask .&. controlMask == 0) $ do
                                 let str' = if isUTF8Encoded str
                                               then decodeString str
                                               else str
                                 insertString str'
                                 updateWindows
                                 updateHighlightedCompl
                                 completed <- tryAutoComplete
                                 when completed $ setSuccess True >> setDone True

setSuccess :: Bool -> XP ()
setSuccess b = modify $ \s -> s { successful = b }

setDone :: Bool -> XP ()
setDone b = modify $ \s -> s { done = b }

-- KeyPress and State

-- | Quit.
quit :: XP ()
quit = flushString >> setSuccess False >> setDone True

-- | Kill the portion of the command before the cursor
killBefore :: XP ()
killBefore =
  modify $ \s -> setCommand (drop (offset s) (command s)) $ s { offset  = 0 }

-- | Kill the portion of the command including and after the cursor
killAfter :: XP ()
killAfter =
  modify $ \s -> setCommand (take (offset s) (command s)) s

-- | Kill the next\/previous word, using 'isSpace' as the default
--   predicate for non-word characters.  See 'killWord''.
killWord :: Direction1D -> XP ()
killWord = killWord' isSpace

-- | Kill the next\/previous word, given a predicate to identify
--   non-word characters. First delete any consecutive non-word
--   characters; then delete consecutive word characters, stopping
--   just before the next non-word character.
--
--   For example, by default (using 'killWord') a path like
--   @foo\/bar\/baz@ would be deleted in its entirety.  Instead you can
--   use something like @killWord' (\\c -> isSpace c || c == \'\/\')@ to
--   delete the path one component at a time.
killWord' :: (Char -> Bool) -> Direction1D -> XP ()
killWord' p d = do
  o <- gets offset
  c <- gets command
  let (f,ss)        = splitAt o c
      delNextWord   = snd . break p . dropWhile p
      delPrevWord   = reverse . delNextWord . reverse
      (ncom,noff)   =
          case d of
            Next -> (f ++ delNextWord ss, o)
            Prev -> (delPrevWord f ++ ss, length $ delPrevWord f) -- laziness!!
  modify $ \s -> setCommand ncom $ s { offset = noff}

-- | Put the cursor at the end of line
endOfLine :: XP ()
endOfLine  =
    modify $ \s -> s { offset = length (command s)}

-- | Put the cursor at the start of line
startOfLine :: XP ()
startOfLine  =
    modify $ \s -> s { offset = 0 }

-- |  Flush the command string and reset the offset
flushString :: XP ()
flushString = modify $ \s -> setCommand "" $ s { offset = 0}

--reset index if config has `alwaysHighlight`. The inserted char could imply fewer autocompletions.
--If the current index was column 2, row 1 and now there are only 4 autocompletion rows with 1 column, what should we highlight? Set it to the first and start navigation again
resetComplIndex :: XPState -> XPState
resetComplIndex st = if (alwaysHighlight $ config st) then st { complIndex = (0,0) } else st

-- | Insert a character at the cursor position
insertString :: String -> XP ()
insertString str =
  modify $ \s -> let
    cmd = (c (command s) (offset s))
    st = resetComplIndex $ s { offset = o (offset s)}
    in setCommand cmd st
  where o oo = oo + length str
        c oc oo | oo >= length oc = oc ++ str
                | otherwise = f ++ str ++ ss
                where (f,ss) = splitAt oo oc

-- | Insert the current X selection string at the cursor position.
pasteString :: XP ()
pasteString = join $ io $ liftM insertString getSelection

-- | Remove a character at the cursor position
deleteString :: Direction1D -> XP ()
deleteString d =
  modify $ \s -> setCommand (c (command s) (offset s)) $ s { offset = o (offset s)}
  where o oo = if d == Prev then max 0 (oo - 1) else oo
        c oc oo
            | oo >= length oc && d == Prev = take (oo - 1) oc
            | oo <  length oc && d == Prev = take (oo - 1) f ++ ss
            | oo <  length oc && d == Next = f ++ tail ss
            | otherwise = oc
            where (f,ss) = splitAt oo oc

-- | move the cursor one position
moveCursor :: Direction1D -> XP ()
moveCursor d =
  modify $ \s -> s { offset = o (offset s) (command s)}
  where o oo c = if d == Prev then max 0 (oo - 1) else min (length c) (oo + 1)

-- | Move the cursor one word, using 'isSpace' as the default
--   predicate for non-word characters.  See 'moveWord''.
moveWord :: Direction1D -> XP ()
moveWord = moveWord' isSpace

-- | Move the cursor one word, given a predicate to identify non-word
--   characters. First move past any consecutive non-word characters;
--   then move to just before the next non-word character.
moveWord' :: (Char -> Bool) -> Direction1D -> XP ()
moveWord' p d = do
  c <- gets command
  o <- gets offset
  let (f,ss) = splitAt o c
      len = uncurry (+)
          . (length *** (length . fst . break p))
          . break (not . p)
      newoff = case d of
                 Prev -> o - len (reverse f)
                 Next -> o + len ss
  modify $ \s -> s { offset = newoff }

moveHistory :: (W.Stack String -> W.Stack String) -> XP ()
moveHistory f = modify $ \s -> let ch = f $ commandHistory s
                               in s { commandHistory = ch
                                    , offset         = length $ W.focus ch }

updateHighlightedCompl :: XP ()
updateHighlightedCompl = do
  st <- get
  cs <- getCompletions
  alwaysHighlight' <- gets $ alwaysHighlight . config
  when (alwaysHighlight') $ modify $ \s -> s {highlightedCompl = highlightedItem st cs}

-- X Stuff

updateWindows :: XP ()
updateWindows = do
  d <- gets dpy
  drawWin
  c <- getCompletions
  case c  of
    [] -> destroyComplWin >> return ()
    l  -> redrawComplWin l
  io $ sync d False

redrawWindows :: [String] -> XP ()
redrawWindows c = do
  d <- gets dpy
  drawWin
  case c of
    [] -> return ()
    l  -> redrawComplWin l
  io $ sync d False

createWin :: Display -> Window -> XPConfig -> Rectangle -> IO Window
createWin d rw c s = do
  let (x,y) = case position c of
                Top -> (0,0)
                Bottom -> (0, rect_height s - height c)
  w <- mkUnmanagedWindow d (defaultScreenOfDisplay d) rw
                      (rect_x s + x) (rect_y s + fi y) (rect_width s) (height c)
  mapWindow d w
  return w

drawWin :: XP ()
drawWin = do
  st <- get
  let (c,(d,(w,gc))) = (config &&& dpy &&& win &&& gcon) st
      scr = defaultScreenOfDisplay d
      wh = widthOfScreen scr
      ht = height c
      bw = promptBorderWidth c
  Just bgcolor <- io $ initColor d (bgColor c)
  Just border  <- io $ initColor d (borderColor c)
  p <- io $ createPixmap d w wh ht
                         (defaultDepthOfScreen scr)
  io $ fillDrawable d p gc border bgcolor (fi bw) wh ht
  printPrompt p
  io $ copyArea d p w gc 0 0 wh ht 0 0
  io $ freePixmap d p

printPrompt :: Drawable -> XP ()
printPrompt drw = do
  st <- get
  let (gc,(c,(d,fs))) = (gcon &&& config &&& dpy &&& fontS) st
      (prt,(com,off)) = (show . currentXPMode &&& command &&& offset) st
      str = prt ++ com
      -- break the string in 3 parts: till the cursor, the cursor and the rest
      (f,p,ss) = if off >= length com
                 then (str, " ","") -- add a space: it will be our cursor ;-)
                 else let (a,b) = (splitAt off com)
                      in (prt ++ a, [head b], tail b)
      ht = height c
  fsl <- io $ textWidthXMF (dpy st) fs f
  psl <- io $ textWidthXMF (dpy st) fs p
  (asc,desc) <- io $ textExtentsXMF fs str
  let y = fi $ ((ht - fi (asc + desc)) `div` 2) + fi asc
      x = (asc + desc) `div` 2

  let draw = printStringXMF d drw fs gc
  -- print the first part
  draw (fgColor c) (bgColor c) x y f
  -- reverse the colors and print the "cursor" ;-)
  draw (bgColor c) (fgColor c) (x + fromIntegral fsl) y p
  -- reverse the colors and print the rest of the string
  draw (fgColor c) (bgColor c) (x + fromIntegral (fsl + psl)) y ss

-- get the current completion function depending on the active mode
getCompletionFunction :: XPState -> ComplFunction
getCompletionFunction st = case operationMode st of
  XPSingleMode compl _ -> compl
  XPMultipleModes modes -> completionFunction $ W.focus modes

-- Completions
getCompletions :: XP [String]
getCompletions = do
  s <- get
  io $ getCompletionFunction s (commandToComplete (currentXPMode s) (command s))
       `E.catch` \(SomeException _) -> return []

setComplWin :: Window -> ComplWindowDim -> XP ()
setComplWin w wi =
  modify (\s -> s { complWin = Just w, complWinDim = Just wi })

destroyComplWin :: XP ()
destroyComplWin = do
  d  <- gets dpy
  cw <- gets complWin
  case cw of
    Just w -> do io $ destroyWindow d w
                 modify (\s -> s { complWin = Nothing, complWinDim = Nothing })
    Nothing -> return ()

type ComplWindowDim = (Position,Position,Dimension,Dimension,Columns,Rows)
type Rows = [Position]
type Columns = [Position]

createComplWin :: ComplWindowDim -> XP Window
createComplWin wi@(x,y,wh,ht,_,_) = do
  st <- get
  let d = dpy st
      scr = defaultScreenOfDisplay d
  w <- io $ mkUnmanagedWindow d scr (rootw st)
                      x y wh ht
  io $ mapWindow d w
  setComplWin w wi
  return w

getComplWinDim :: [String] -> XP ComplWindowDim
getComplWinDim compl = do
  st <- get
  let (c,(scr,fs)) = (config &&& screen &&& fontS) st
      wh = rect_width scr
      ht = height c

  tws <- mapM (textWidthXMF (dpy st) fs) compl
  let max_compl_len =  fromIntegral ((fi ht `div` 2) + maximum tws)
      columns = max 1 $ wh `div` fi max_compl_len
      rem_height =  rect_height scr - ht
      (rows,r) = length compl `divMod` fi columns
      needed_rows = max 1 (rows + if r == 0 then 0 else 1)
      limit_max_number = case maxComplRows c of
                           Nothing -> id
                           Just m -> min m
      actual_max_number_of_rows = limit_max_number $ rem_height `div` ht
      actual_rows = min actual_max_number_of_rows (fi needed_rows)
      actual_height = actual_rows * ht
      (x,y) = case position c of
                Top -> (0,ht)
                Bottom -> (0, (0 + rem_height - actual_height))
  (asc,desc) <- io $ textExtentsXMF fs $ head compl
  let yp = fi $ (ht + fi (asc - desc)) `div` 2
      xp = (asc + desc) `div` 2
      yy = map fi . take (fi actual_rows) $ [yp,(yp + ht)..]
      xx = take (fi columns) [xp,(xp + max_compl_len)..]

  return (rect_x scr + x, rect_y scr + fi y, wh, actual_height, xx, yy)

drawComplWin :: Window -> [String] -> XP ()
drawComplWin w compl = do
  st <- get
  let c   = config st
      d   = dpy st
      scr = defaultScreenOfDisplay d
      bw  = promptBorderWidth c
      gc  = gcon st
  Just bgcolor <- io $ initColor d (bgColor c)
  Just border  <- io $ initColor d (borderColor c)

  (_,_,wh,ht,xx,yy) <- getComplWinDim compl

  p <- io $ createPixmap d w wh ht
                         (defaultDepthOfScreen scr)
  io $ fillDrawable d p gc border bgcolor (fi bw) wh ht
  let ac = splitInSubListsAt (length yy) (take (length xx * length yy) compl)

  printComplList d p gc (fgColor c) (bgColor c) xx yy ac
  --lift $ spawn $ "xmessage " ++ " ac: " ++ show ac  ++ " xx: " ++ show xx ++ " length xx: " ++ show (length xx) ++ " yy: " ++ show (length yy)
  io $ copyArea d p w gc 0 0 wh ht 0 0
  io $ freePixmap d p

redrawComplWin ::  [String] -> XP ()
redrawComplWin compl = do
  st <- get
  nwi <- getComplWinDim compl
  let recreate = do destroyComplWin
                    w <- createComplWin nwi
                    drawComplWin w compl
  if compl /= [] && showComplWin st
     then case complWin st of
            Just w -> case complWinDim st of
                        Just wi -> if nwi == wi -- complWinDim did not change
                                   then drawComplWin w compl -- so update
                                   else recreate
                        Nothing -> recreate
            Nothing -> recreate
     else destroyComplWin

-- Finds the column and row indexes in which a string appears.
-- if the string is not in the matrix, the indexes default to (0,0)
findComplIndex :: String -> [[String]] -> (Int,Int)
findComplIndex x xss = let
  colIndex = fromMaybe 0 $ findIndex (\cols -> x `elem` cols) xss
  rowIndex = fromMaybe 0 $ elemIndex x $ (!!) xss colIndex
  in (colIndex,rowIndex)

printComplList :: Display -> Drawable -> GC -> String -> String
               -> [Position] -> [Position] -> [[String]] -> XP ()
printComplList d drw gc fc bc xs ys sss =
    zipWithM_ (\x ss ->
        zipWithM_ (\y item -> do
            st <- get
            alwaysHlight <- gets $ alwaysHighlight . config
            let (h,f,b) = case alwaysHlight of
                  True -> -- default to the first item, the one in (0,0)
                    let
                      (colIndex,rowIndex) = findComplIndex item sss
                    in -- assign some colors
                     if ((complIndex st) == (colIndex,rowIndex)) then (True, fgHLight $ config st,bgHLight $ config st)
                     else (False, fc,bc)
                  False ->
                    -- compare item with buffer's value
                    if highlightPredicate (currentXPMode st) item (command st, offset st)
                    then (True, fgHLight $ config st,bgHLight $ config st)
                    else (False, fc,bc)
            printStringXMF d drw (fontS st) gc f b x y item)
            -- ansi color printing
            -- if h then printStringXMF d drw (fontS st) gc f b x y (deANSI item)
            --      else printANSIColorStr (ansiToHex $ config st) d drw (fontS st) gc f b f b x y item)
        ys ss) xs sss

deANSI "" = ""
deANSI str = let (b,_,_,a) = parseANSI (\_->"") "" "" "" "" str in b ++ deANSI a
parseANSI fun df db f b str = case break (=='\ESC') str of
                             (bef, "") -> (bef, f, b, "")
                             (bef, seq) -> case break (=='m') seq of
                                ('\ESC':'[':'3':'8':';':'5':';':code, 'm':aft) -> (bef, hex code, b, aft)
                                ('\ESC':'[':'4':'8':';':'5':';':code, 'm':aft) -> (bef, f, hex code, aft)
                                ("\ESC[0", 'm':aft) -> (bef, df, db, aft)
                                ('\ESC':'[':'3':c:[], 'm':aft) -> (bef, hex [c], b, aft)
                                ('\ESC':'[':'4':c:[], 'm':aft) -> (bef, f, hex [c], aft)
                                (_, _:aft) -> (bef, f, b, aft)
                                (_:plain,_) -> (bef, f, b, plain) 
                        where hex = fun . fromMaybe 0 . readMaybe

-- drawing prototype
printANSIColorStr fun d drw font gc df db f b x y [] = return ()
printANSIColorStr fun d drw font gc df db f b x y str = do
    -- first parse the str to get to the next escape sequence
    let (bef, fg, bg, aft) = parseANSI fun df db f b str
    printStringXMF d drw font gc f b x y bef
    wid <- io $ textWidthXMF d font bef
    printANSIColorStr fun d drw font gc df db fg bg (x+fromIntegral wid) y aft
           

-- History

type History = M.Map String [String]

emptyHistory :: History
emptyHistory = M.empty

getHistoryFile :: IO FilePath
getHistoryFile = fmap (++ "/history") $ getAppUserDataDirectory "xmonad"

readHistory :: IO History
readHistory = readHist `E.catch` \(SomeException _) -> return emptyHistory
 where
    readHist = do
        path <- getHistoryFile
        xs <- bracket (openFile path ReadMode) hClose hGetLine
        readIO xs

writeHistory :: History -> IO ()
writeHistory hist = do
  path <- getHistoryFile
  let filtered = M.filter (not . null) hist
  writeFile path (show filtered) `E.catch` \(SomeException e) ->
                          hPutStrLn stderr ("error writing history: "++show e)
  setFileMode path mode
    where mode = ownerReadMode .|. ownerWriteMode

-- $xutils

-- | Fills a 'Drawable' with a rectangle and a border
fillDrawable :: Display -> Drawable -> GC -> Pixel -> Pixel
             -> Dimension -> Dimension -> Dimension -> IO ()
fillDrawable d drw gc border bgcolor bw wh ht = do
  -- we start with the border
  setForeground d gc border
  fillRectangle d drw gc 0 0 wh ht
  -- here foreground means the background of the text
  setForeground d gc bgcolor
  fillRectangle d drw gc (fi bw) (fi bw) (wh - (bw * 2)) (ht - (bw * 2))

-- | Creates a window with the attribute override_redirect set to True.
-- Windows Managers should not touch this kind of windows.
mkUnmanagedWindow :: Display -> Screen -> Window -> Position
                  -> Position -> Dimension -> Dimension -> IO Window
mkUnmanagedWindow d s rw x y w h = do
  let visual = defaultVisualOfScreen s
      attrmask = cWOverrideRedirect
  allocaSetWindowAttributes $
         \attributes -> do
           set_override_redirect attributes True
           createWindow d rw x y w h 0 (defaultDepthOfScreen s)
                        inputOutput visual attrmask attributes

-- $utils

-- | This function takes a list of possible completions and returns a
-- completions function to be used with 'mkXPrompt'
mkComplFunFromList :: [String] -> String -> IO [String]
mkComplFunFromList _ [] = return []
mkComplFunFromList l s =
  return $ filter (\x -> take (length s) x == s) l

-- | This function takes a list of possible completions and returns a
-- completions function to be used with 'mkXPrompt'. If the string is
-- null it will return all completions.
mkComplFunFromList' :: [String] -> String -> IO [String]
mkComplFunFromList' l [] = return l
mkComplFunFromList' l s =
  return $ filter (\x -> take (length s) x == s) l


-- | Given the prompt type, the command line and the completion list,
-- return the next completion in the list for the last word of the
-- command line. This is the default 'nextCompletion' implementation.
getNextOfLastWord :: XPrompt t => t -> (String, Int) -> [String] -> (String, Int)
getNextOfLastWord t (c,_) l = (c', length c')
    where ni = case commandToComplete t c `elemIndex` map (completionToCommand t) l of
                 Just i -> if i >= length l - 1 then 0 else i + 1
                 Nothing -> 0
          c' = skipLastWord c ++ completionToCommand t (l !! ni)

-- | An alternative 'nextCompletion' implementation: given a command
-- and a completion list, get the next completion in the list matching
-- the whole command line.
getNextCompletion :: (String, Int) -> [String] -> (String, Int)
getNextCompletion (c,_) l = (c', length c')
    where idx = case c `elemIndex` l of
                  Just i  -> if i >= length l - 1 then 0 else i + 1
                  Nothing -> 0
          c' = l !! idx

-- | Given a maximum length, splits a list into sublists
splitInSubListsAt :: Int -> [a] -> [[a]]
splitInSubListsAt _ [] = []
splitInSubListsAt i x = f : splitInSubListsAt i rest
    where (f,rest) = splitAt i x

-- | Gets the last word of a string or the whole string if formed by
-- only one word
getLastWord :: String -> String
getLastWord = reverse . fst . breakAtSpace . reverse

-- | Skips the last word of the string, if the string is composed by
-- more then one word. Otherwise returns the string.
skipLastWord :: String -> String
skipLastWord = reverse . snd . breakAtSpace . reverse

breakAtSpace :: String -> (String, String)
breakAtSpace s
    | " \\" `isPrefixOf` s2 = (s1 ++ " " ++ s1', s2')
    | otherwise = (s1, s2)
      where (s1, s2 ) = break isSpace s
            (s1',s2') = breakAtSpace $ tail s2

-- | 'historyCompletion' provides a canned completion function much like
--   'getShellCompl'; you pass it to mkXPrompt, and it will make completions work
--   from the query history stored in ~\/.xmonad\/history.
historyCompletion :: ComplFunction
historyCompletion = historyCompletionP (const True)

-- | Like 'historyCompletion' but only uses history data from Prompts whose
-- name satisfies the given predicate.
historyCompletionP :: (String -> Bool) -> ComplFunction
historyCompletionP p x = fmap (toComplList . M.filterWithKey (const . p)) readHistory
    where toComplList = deleteConsecutive . filter (isInfixOf x) . M.fold (++) []

-- | Sort a list and remove duplicates. Like 'deleteAllDuplicates', but trades off
--   laziness and stability for efficiency.
uniqSort :: Ord a => [a] -> [a]
uniqSort = toList . fromList

-- | Functions to be used with the 'historyFilter' setting.
-- 'deleteAllDuplicates' will remove all duplicate entries.
-- 'deleteConsecutive' will only remove duplicate elements
-- immediately next to each other.
deleteAllDuplicates, deleteConsecutive :: [String] -> [String]
deleteAllDuplicates = nub
deleteConsecutive = map head . group

newtype HistoryMatches = HistoryMatches (IORef ([String],Maybe (W.Stack String), Int))

-- | Initializes a new HistoryMatches structure to be passed
-- to historyUpMatching
initMatches' :: (Functor m, MonadIO m) => Int -> m HistoryMatches
initMatches' pid = HistoryMatches <$> liftIO (newIORef ([],Nothing,pid))
-- default to initialize using pid 0, which corresponds to the prefix predicate matching
initMatches :: (Functor m, MonadIO m) => m HistoryMatches
initMatches = initMatches' 0

historyNextMatching :: HistoryMatches -> (W.Stack String -> W.Stack String) -> XP ()
historyNextMatching = historyNextMatching' isPrefixOf 0

historyNextMatching' :: (String -> String -> Bool) -> Int -> HistoryMatches -> (W.Stack String -> W.Stack String) -> XP ()
historyNextMatching' predicate pid hm@(HistoryMatches ref) next = do
  (completed,completions,oid) <- io $ readIORef ref
  input <- getInput
  if input `elem` completed && pid == oid
     then case completions of
            Just cs -> do
                let cmd = W.focus cs
                modify $ setCommand cmd
                modify $ \s -> s { offset = length cmd }
                io $ writeIORef ref (cmd:completed,Just $ next cs, pid)
            Nothing -> return ()
     else do -- the user typed something new, recompute completions
       io . writeIORef ref . (\a -> ([input],a, pid)) . filterMatching input =<< gets commandHistory
       historyNextMatching' predicate pid hm next
    where filterMatching :: String -> W.Stack String -> Maybe (W.Stack String)
          filterMatching prefix = W.filter (prefix `predicate`) . next

-- | Retrieve the next history element that starts with
-- the current input. Pass it the result of initMatches
-- when creating the prompt. Example:
--
-- > ..
-- > ((modMask,xK_p), shellPrompt . myPrompt =<< initMatches)
-- > ..
-- > myPrompt ref = def
-- >   { promptKeymap = M.union [((0,xK_Up), historyUpMatching ref)
-- >                            ,((0,xK_Down), historyDownMatching ref)]
-- >                            (promptKeymap def)
-- >   , .. }
--
historyUpMatching, historyDownMatching :: HistoryMatches -> XP ()
historyUpMatching hm = historyNextMatching hm W.focusDown'
historyDownMatching hm = historyNextMatching hm W.focusUp'

historyUpMatchingP, historyDownMatchingP :: (String -> String -> Bool) -> Int -> HistoryMatches -> XP ()
historyUpMatchingP p pid hm = historyNextMatching' p pid hm W.focusDown'
historyDownMatchingP p pid hm = historyNextMatching' p pid hm W.focusUp'

-- LN: custom functions that are usualy useful for prompts
findWord (w:ws) toMatch = w `elem` toMatch || findWord ws toMatch
findWord [] toMatch = False

fillSpace col s 
    | (length s) < col = fillSpace col (s++" ")
    | otherwise = s

infixSearchPredicate cmd cpl = isInfixOf (map toLower cmd) (map toLower cpl) 

prefixSearchPredicate cmd cpl = isPrefixOf (map toLower cmd) (map toLower cpl)

-- an implementation for searchPredicate that will make sure all words typed are contained in the result
repeatedGrep cmd cpl = all (`isInfixOf` lp) (words lc) 
    where lc = map toLower cmd
          lp = map toLower cpl
