build:
	stack build

haddock:
	stack haddock

clean:
	stack clean

run: build
	stack exec -- freetype2-hs
