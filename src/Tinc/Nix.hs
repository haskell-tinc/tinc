{-# LANGUAGE CPP #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RecordWildCards #-}
module Tinc.Nix (
  NixCache
, cabal
, nixShell
, resolverFile
, createDerivations
#ifdef TEST
, Function (..)
, defaultDerivation
, shellDerivation
, resolverDerivation
, pkgImport
, parseNixFunction
, disableTests
, extractDependencies
, derivationFile
#endif
) where

import           Data.Char
import           Data.Maybe
import           Data.List
import           System.Directory
import           System.FilePath
import           System.Process.Internals (translate)
import           System.Process
import           System.IO

import           Tinc.Facts
import           Tinc.Package
import           Tinc.Types
import           Tinc.SourceDependency
import           Util

type NixExpression = String
type Argument = String
type HaskellDependency = String
type SystemDependency = String
data Function = Function {
  _functionArguments :: [Argument]
, _functionBody :: NixExpression
} deriving (Eq, Show)

packageFile :: FilePath
packageFile = "package.nix"

resolverFile :: FilePath
resolverFile = "tinc.nix"

defaultFile :: FilePath
defaultFile = "default.nix"

shellFile :: FilePath
shellFile = "shell.nix"

formatNixResolver :: Facts -> String
formatNixResolver Facts{..} = maybe "haskellPackages" (("haskell.packages." ++) . show) factsNixResolver

cabal :: Facts -> [String] -> (String, [String])
cabal facts args = ("nix-shell", ["-p", "curl", formatNixResolver facts ++ ".ghcWithPackages (p: [ p.cabal-install ])", "--pure", "--run", unwords $ "cabal" : map translate args])

nixShell :: String -> [String] -> (String, [String])
nixShell command args = ("nix-shell", [shellFile, "--run", unwords $ command : map translate args])

createDerivations :: Facts -> [Package] -> IO ()
createDerivations facts@Facts{..} dependencies = do
  mapM_ (populateCache factsSourceDependencyCache factsNixCache) dependencies
  pkgDerivation <- cabalToNix "."

  let knownHaskellDependencies = map packageName dependencies
  mapM (readDependencies factsNixCache knownHaskellDependencies) dependencies >>= resolverDerivation facts >>= writeFile resolverFile
  writeFile packageFile pkgDerivation
  writeFile defaultFile defaultDerivation
  writeFile shellFile shellDerivation

populateCache :: Path SourceDependencyCache -> Path NixCache -> Package -> IO ()
populateCache sourceDependencyCache cache pkg = do
  _ <- cachedIO (derivationFile cache pkg) $ disableDocumentation . disableTests <$> go
  return ()
  where
    go = case pkg of
      Package _ (Version _ Nothing) -> cabalToNix ("cabal://" ++ showPackage pkg)
      Package name (Version _ (Just ref)) -> do
        let p = path . sourceDependencyPath sourceDependencyCache $ SourceDependency name ref
        canonicalizePath p >>= cabalToNix

disable :: String -> NixExpression -> NixExpression
disable s xs = case lines xs of
  ys | attribute `elem` ys -> xs
  ys -> unlines . (++ [attribute, "}"]) . init $ ys
  where
    attribute = "  " ++ s ++ " = false;"

disableTests :: NixExpression -> NixExpression
disableTests = disable "doCheck"

disableDocumentation :: NixExpression -> NixExpression
disableDocumentation = disable "doHaddock"

cabalToNix :: String -> IO NixExpression
cabalToNix uri = do
  hPutStrLn stderr $ "cabal2nix " ++ uri
  readProcess "cabal2nix" [uri] ""

defaultDerivation :: NixExpression
defaultDerivation = unlines [
    "let"
  , "  default = { nixpkgs ? import <nixpkgs> {} }:"
  , "    (import ./" ++ resolverFile ++ " { inherit nixpkgs; }).resolver.callPackage ./" ++ packageFile ++ " {};"
  , "  overrideFile = ./default-override.nix;"
  , "  expr = if builtins.pathExists overrideFile then import overrideFile else default;"
  , "in expr"
  ]

shellDerivation :: NixExpression
shellDerivation = unlines [
    "{ nixpkgs ? import <nixpkgs> {} }:"
  , "(import ./" ++ defaultFile ++ " { inherit nixpkgs; }).env"
  ]

indent :: Int -> [String] -> [String]
indent n = map f
  where
    f xs = case xs of
      "" -> ""
      _ -> replicate n ' ' ++ xs

resolverDerivation :: Facts -> [(Package, [HaskellDependency], [SystemDependency])] -> IO NixExpression
resolverDerivation facts@Facts{..} dependencies = do
  overrides <- concat <$> mapM getPkgDerivation dependencies
  return . unlines $ [
      "{ nixpkgs }:"
    , "rec {"
    , "  compiler = nixpkgs." ++ formatNixResolver facts ++ ";"
    , "  resolver ="
    ] ++ indent 4 [
      "let"
    , "  callPackage = compiler.callPackage;"
    , ""
    , "  overrideFunction = self: super: rec {"
    ] ++ indent 8 overrides ++
    indent 4 [
      "  };"
    , ""
    , "  newResolver = compiler.override {"
    , "    overrides = overrideFunction;"
    , "  };"
    , ""
    , "in newResolver;"
    ] ++ ["}"]
  where
    getPkgDerivation packageDeps@(package, _, _) = pkgImport packageDeps <$> readFile (derivationFile factsNixCache package)

pkgImport :: (Package, [HaskellDependency], [SystemDependency]) -> NixExpression -> [String]
pkgImport ((Package name _), haskellDependencies, systemDependencies) derivation = begin : indent 2 definition
  where
    begin = name ++ " = callPackage"
    derivationLines = lines derivation
    inlineDerivation = ["("] ++ indent 2 derivationLines ++ [")"]
    args = "{ " ++ inheritHaskellDependencies ++ inheritSystemDependencies ++ "};"
    definition = inlineDerivation ++ [args]
    inheritHaskellDependencies
      | null haskellDependencies = ""
      | otherwise = "inherit " ++ intercalate " " haskellDependencies ++ "; "
    inheritSystemDependencies
      | null systemDependencies = ""
      | otherwise = "inherit (nixpkgs) " ++ intercalate " " systemDependencies ++ "; "

readDependencies :: Path NixCache -> [HaskellDependency] -> Package -> IO (Package, [HaskellDependency], [SystemDependency])
readDependencies cache knownHaskellDependencies package = do
  (\(haskellDeps, systemDeps) -> (package, haskellDeps, systemDeps)) . (`extractDependencies` knownHaskellDependencies)  . parseNixFunction <$> readFile (derivationFile cache package)

derivationFile :: Path NixCache -> Package -> FilePath
derivationFile cache package = path cache </> showPackage package ++ rev ++ ".nix"
  where
    rev = case packageVersion package of
      Version _ (Just hash) -> "-" ++ hash
      _ -> ""

parseNixFunction :: NixExpression -> Function
parseNixFunction xs = case break (== '}') xs of
  (args, body) -> Function (split . filter (not . isSpace). dropWhile (`elem` "{ ") $ args) (dropWhile (`elem` "}: ") body)
  where
    split :: String -> [Argument]
    split = go ""
      where
        go acc ys = case ys of
          ',' : zs -> reverse acc : go "" zs
          z : zs -> go (z : acc) zs
          "" -> [reverse acc]

extractDependencies :: Function -> [HaskellDependency] -> ([HaskellDependency], [SystemDependency])
extractDependencies (Function args body) knownHaskellDependencies =
  (haskellDependencies, systemDependencies)
  where
    haskellDependencies = filter (`notElem` systemDependencies) . filter (`elem` knownHaskellDependencies) $ args
    systemDependencies = parseSystemDependencies body

parseSystemDependencies :: NixExpression -> [SystemDependency]
parseSystemDependencies body = concatMap (words . takeWhile (/= ']')) . mapMaybe (stripPrefix "librarySystemDepends = [" . dropWhile isSpace) . lines $ body
