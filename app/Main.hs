module Main where

import qualified Graphics.Rendering.FreeType as F

main :: IO ()
main =
  F.withFreeType $ \ft ->
  F.withFontFace ft "/usr/share/fonts/truetype/freefont/FreeSans.ttf" $ \ff -> do
    font <- F.storeCache $ F.newCharactersCache ff $ curry print
    cs <- F.getStoredStr font $ F.TextQuery (F.Height 48) "abcda"
    print cs
