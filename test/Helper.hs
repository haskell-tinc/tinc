{-# LANGUAGE OverloadedStrings #-}
module Helper (
  module Test.Hspec
, ensureCache
, cache
, setenv
, getoptGenericsSandbox
, getoptGenerics
, hspecDiscover
, getoptGenericsPackages
, removeDirectory
, setenvSandbox
) where

import           Prelude ()
import           Prelude.Compat

import           Test.Hspec

import           Control.Monad
import           System.Directory hiding (removeDirectory)
import           System.Environment.Compat
import           System.FilePath
import           System.Process
import           Test.Mockery.Directory
import           Shelly (shelly, rm_rf, cp_r)
import           Data.String

import           Util
import           Package
import           Tinc.Types
import           Tinc.Install

ensureCache :: IO ()
ensureCache = do
  unsetEnvVars
  mkCache
  restoreCache

unsetEnvVars :: IO ()
unsetEnvVars = do
  unsetEnv "CABAL_SANDBOX_CONFIG"
  unsetEnv "CABAL_SANDBOX_PACKAGE_PATH"
  unsetEnv "GHC_PACKAGE_PATH"

withDirectory :: FilePath -> IO a -> IO a
withDirectory dir action = do
  createDirectoryIfMissing True dir
  withCurrentDirectory dir action

getoptGenerics :: Package
getoptGenerics = Package "getopt-generics" "0.6.3"

hspecDiscover :: Package
hspecDiscover = Package "hspec-discover" "2.1.7"

genericsSop :: Package
genericsSop = Package "generics-sop" "0.1.1.2"

setenv :: Package
setenv = Package "setenv" "0.1.1.3"

getoptGenericsPackages :: [Package]
getoptGenericsPackages = [
    Package "base-compat" "0.8.2"
  , Package "base-orphans" "0.3.2"
  , genericsSop
  , Package "tagged" "0.8.0.1"
  , hspecDiscover
  , getoptGenerics
  ]

mkTestSandbox :: String -> [Package] -> IO ()
mkTestSandbox pattern packages = do
  let sandbox = toSandbox pattern
  exists <- doesDirectoryExist $ path sandbox
  when (not exists) $ do
    createDirectoryIfMissing True $ path sandbox
    withDirectory (path sandbox) $ do
      callCommand "cabal sandbox init"
      callCommand ("cabal install --disable-library-profiling --disable-optimization --disable-documentation " ++
                   unwords (map showPackage packages))

mkCache :: IO ()
mkCache = do
  exists <- doesDirectoryExist (path cacheBackup)
  unless exists $ do
    removeDirectory cache
    createDirectory (path cache)
    mkTestSandbox "setenv" [setenv]
    mkTestSandbox "getopt-generics" getoptGenericsPackages
    copyDirectory cache cacheBackup

restoreCache :: IO ()
restoreCache = do
  removeDirectory cache
  copyDirectory cacheBackup cache
  forM_ [getoptGenericsSandbox, setenvSandbox] $ \ sandbox -> do
    Path packageDB <- findPackageDB sandbox
    touch (packageDB </> "package.cache")

cache :: Path Cache
cache = "/tmp/tinc-test-cache"

cacheBackup :: Path Cache
cacheBackup = "cache-backup"

copyDirectory :: Path a -> Path a -> IO ()
copyDirectory src dst = shelly $ do
  cp_r (fromString $ path src) (fromString $ path dst)

removeDirectory :: Path a -> IO ()
removeDirectory dir = shelly $ do
  rm_rf (fromString $ path dir)

toSandbox :: String -> Path Sandbox
toSandbox pattern = Path (path cache </> "tinc-" ++ pattern)

setenvSandbox :: Path Sandbox
setenvSandbox = toSandbox "setenv"

getoptGenericsSandbox :: Path Sandbox
getoptGenericsSandbox = toSandbox "getopt-generics"
