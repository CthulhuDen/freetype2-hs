{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

-- | Description: Bindings to freetype2 font rendering library
-- This module provides somewhat-higher-level (limited) subset of freetype2 library,
-- based of <http://hackage.haskell.org/package/freetype2-0.1.2 freetype2> low-level package.
module Graphics.Rendering.FreeType
  ( -- * Generic FreeType types
    FreeTypeError (..)
    -- | The following types are re-exported directly from freetype2 so you can use low-level functions.
  , F.FT_Library
  , F.FT_Face
    -- * Creating context/face
  , withFreeType
  , withFontFace
    -- * Obtaining rendered characters
    -- ** Data types
  , PixelSizes (..)
  , CharacterMetrics (..)
  , CharactersCache
  , newCharactersCache
  , addPreprocessor
    -- ** Functions
  , getCached
  , getCachedStr
    -- * Helper data types to store cache in IORef
    -- | Note that these are not thread-safe so should not be accessed from multiple threads at a time.
  , CharactersStore
  , storeCache
  , getStored
  , getStoredStr
  ) where

import Control.Exception.Safe
import Control.Monad
import Data.Bifunctor (first)
import Data.Char (ord)
import Data.Function
import Data.Functor
import Data.Hashable
import Data.IORef
import qualified Data.HashMap.Strict as M
import Foreign
import Foreign.C
import GHC.Generics
import Prelude hiding (getChar)

import qualified Graphics.Rendering.FreeType.Internal as F
import qualified Graphics.Rendering.FreeType.Internal.Bitmap as FB
import qualified Graphics.Rendering.FreeType.Internal.Face as F
import qualified Graphics.Rendering.FreeType.Internal.GlyphMetrics as FG
import qualified Graphics.Rendering.FreeType.Internal.GlyphSlot as FG
import qualified Graphics.Rendering.FreeType.Internal.Library as F
import qualified Graphics.Rendering.FreeType.Internal.PrimitiveTypes as F

{-# ANN FreeTypeError ("HLint: ignore Use newtype instead of data") #-}
-- | Most of freetype2 c functions report errors via return codes.
-- We check the function exit codes and throw this exception in case of an error.
data FreeTypeError = FreeTypeError !F.FT_Error

instance Show FreeTypeError where
  show (FreeTypeError err) = "FreeType error #" <> show err

instance Exception FreeTypeError

-- | Run FreeType function and throw if FreeType reported an error.
throwErr :: IO F.FT_Error -> IO ()
throwErr act = act >>= \case
  0 -> pure ()
  e -> throwIO $ FreeTypeError e


-- | Initialize FreeType context and run some IO action against it.
--
-- NOTE: when the action finishes the FreeType library will be immediately destroyed
-- so make sure not to export library pointer out of the action as it will become invalid.
withFreeType :: (F.FT_Library -> IO a) -> IO a
withFreeType act = alloca $ \ptr ->
  bracket_ (throwErr $ F.ft_Init_FreeType ptr)
           (F.ft_Done_FreeType =<< peek ptr)
           (act =<< peek ptr)

-- | Initialize FreeType font face and run some IO action against it.
--
-- NOTE: when action finishes the font face will immediately be destroyed
-- so make sure not to export font face pointer out of the action as it will inevitably become invalid.
withFontFace :: F.FT_Library -> FilePath -> (F.FT_Face -> IO a) -> IO a
withFontFace ft fp act = alloca $ \ptr ->
  withCString fp $ \fpPtr ->
    bracket_ (throwErr $ F.ft_New_Face ft fpPtr 0 ptr)
             (F.ft_Done_Face =<< peek ptr)
             (act =<< peek ptr)

-- | Pixel size can be specified either by width or height (with the second parameter being calculated automatically),
-- or by width and height both.
data PixelSizes = WidthHeight !Int !Int | Height !Int | Width !Int
  deriving (Eq, Generic)

instance Hashable PixelSizes

setPixelSizes :: F.FT_Face -> PixelSizes -> IO ()
setPixelSizes ff = throwErr . \case
  WidthHeight w h -> F.ft_Set_Pixel_Sizes ff (fromIntegral w) (fromIntegral h)
  Height h        -> F.ft_Set_Pixel_Sizes ff 0 (fromIntegral h)
  Width w         -> F.ft_Set_Pixel_Sizes ff (fromIntegral w) 0

loadChar :: F.FT_Face -> Char -> IO ()
loadChar ff c = throwErr $ F.ft_Load_Char ff (fromIntegral $ ord c) F.ft_LOAD_RENDER

-- | Character metrics represents the space which should be allocated to display some character in pixels.
data CharacterMetrics = CharacterMetrics
  { cmWidth    :: !Int
  , cmHeight   :: !Int
  , cmBearingX :: !Int
  , cmBearingY :: !Int
  , cmAdvance  :: !Int
  } deriving (Show)

readChar :: F.FT_Face -> IO (Ptr CChar, CharacterMetrics)
readChar ff = do
  gs <- peek $ F.glyph ff
  chBitmap <- FB.buffer <$> peek (FG.bitmap gs)
  metrics <- peek (FG.metrics gs)
  let cmWidth = fromIntegral $ FG.width metrics `quot` 64
      cmHeight = fromIntegral $ FG.height metrics `quot` 64
      cmBearingX = fromIntegral $ FG.horiBearingX metrics `quot` 64
      cmBearingY = fromIntegral $ FG.horiBearingY metrics `quot` 64
      cmAdvance = fromIntegral $ FG.horiAdvance metrics `quot` 64
  pure (chBitmap, CharacterMetrics {..})

-- | Data identifying which character(s) and in which font size to retrieve from font face.
data TextQuery t = TextQuery
  { cqSizes :: !PixelSizes
  , cqSubj  :: !t
  } deriving (Eq, Generic)

instance Hashable t => Hashable (TextQuery t)

getChar :: F.FT_Face -> TextQuery Char -> IO (Ptr CChar, CharacterMetrics)
getChar ff TextQuery {..} = setPixelSizes ff cqSizes *> loadChar ff cqSubj *> readChar ff

-- | Storage of already rendered characters to avoid repetitive rendering of the same character multiple times.
data CharactersCache m = CharactersCache
  { ccFontFace   :: !F.FT_Face
  , ccPreprocess :: !(Ptr CChar -> CharacterMetrics -> IO m)
  , ccCharacters :: !(M.HashMap (TextQuery Char) (m, CharacterMetrics))
  }

-- | Build new characters cache which applies given action to glyph buffer before storing it.
--
-- NOTE: You MUST copy the buffer storage because each new character replaces the old buffer at the same location.
newCharactersCache :: F.FT_Face -> (Ptr CChar -> CharacterMetrics -> IO a) -> CharactersCache a
newCharactersCache ff f = CharactersCache ff f mempty

-- | Add preprocessor to be applied to all buffers before storing them. Also applies to already stored buffers.
-- This action will be called after the previously registered ones.
addPreprocessor :: (a -> CharacterMetrics -> IO b) -> CharactersCache a -> IO (CharactersCache b)
addPreprocessor f CharactersCache {..} =
  CharactersCache ccFontFace preprocess <$> traverse (\(c, m) ->(,) <$> f c m <*> pure m) ccCharacters
  where
    preprocess p m = do
      x <- ccPreprocess p m
      f x m

-- | Get character rendered buffer and metrics from cache (if already cached) or update cache otherwise
getCached :: CharactersCache a -> PixelSizes -> Char -> IO ((a, CharacterMetrics), CharactersCache a)
getCached c@CharactersCache {..} cqSizes cqSubj = case M.lookup q ccCharacters of
  Just r  -> pure (r, c)
  Nothing -> do
    (a, m) <- getChar ccFontFace q
    a' <- ccPreprocess a m
    pure ((a', m), c { ccCharacters = M.insert q (a', m) ccCharacters })
  where
    q = TextQuery {..}

-- | Render each character in the string. Uses cache instead of rendering again the same character.
getCachedStr :: CharactersCache a -> PixelSizes -> String -> IO ([(a, CharacterMetrics)], CharactersCache a)
getCachedStr c cqSizes = go c
  where
    go c' []     = pure ([], c')
    go c' (q:qs) = do
      (x, c'') <- getCached c' cqSizes q
      first (x:) <$> go c'' qs

-- | Characters store is the same as 'CharactersCache', but keeping state in 'IORef' implicitly.
newtype CharactersStore a = CharactersStore (IORef (CharactersCache a))

-- | Store the given cache in 'IORef' to handle the state implicitly.
storeCache :: CharactersCache a -> IO (CharactersStore a)
storeCache = fmap CharactersStore . newIORef

withStored :: CharactersStore a -> (CharactersCache a -> IO (b, CharactersCache a)) -> IO b
withStored (CharactersStore r) act = do
  c <- readIORef r
  (x, c') <- act c
  writeIORef r c' $> x

-- | Get character rendered buffer and metrics from cache if possible, or rendered anew.
getStored :: CharactersStore a -> PixelSizes -> Char -> IO (a, CharacterMetrics)
getStored r s q = withStored r $ \c -> getCached c s q

-- | Render each character in the string, using cache whenever possible.
getStoredStr :: CharactersStore a -> PixelSizes -> String -> IO [(a, CharacterMetrics)]
getStoredStr r s q = withStored r $ \c -> getCachedStr c s q