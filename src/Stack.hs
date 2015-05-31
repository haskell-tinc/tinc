
module Stack where

import           Prelude ()
import           Prelude.Compat

import           Control.Exception
import           Data.List
import           Data.Maybe
import           Data.Traversable
import           System.Directory
import           System.Exit.Compat
import           System.FilePath
import           System.IO
import           System.Process

import           Graph
import           Util


initSandbox :: IO (Path PackageDB)
initSandbox = do
  callCommand "cabal sandbox init"
  findPackageDB (Path "." :: Path SandboxParent)

installDependencies :: Path SandboxParent -> IO ()
installDependencies cache = do
  destPackageDB <- initSandbox
  packages <- parseInstallPlan <$> readProcess "cabal" (command ++ ["--dry-run"]) ""
  packageDB <- findPackageDB cache
  lookupPackages packageDB packages >>= mapM_ (registerPackage destPackageDB)
  callProcess "cabal" command
  where
    command = words "install --only-dependencies"

createStackedSandbox :: Path SandboxParent -> IO ()
createStackedSandbox source = do
  destPackageDB <- initSandbox
  sourcePackageDB <- findPackageDB source
  packages <- extractPackages sourcePackageDB
  mapM_ (registerPackage destPackageDB) packages

findPackageDB :: Path SandboxParent -> IO (Path PackageDB)
findPackageDB dir = do
  mr <-
    listToMaybe <$>
    filter ("-packages.conf.d" `isSuffixOf`) <$>
    getDirectoryContents (path dir </> ".cabal-sandbox")
  maybe
    (die ("package db not found in " ++ path dir))
    (\ p -> Path <$> canonicalizePath (path dir </> ".cabal-sandbox" </> p))
    mr

extractPackages :: Path PackageDB -> IO [Path Package]
extractPackages packageDB = do
  globalPackageDB <- findGlobalPackageDB
  dot <- readProcess "ghc-pkg"
    ("--package-db" : path globalPackageDB :
     "--package-db" : path packageDB :
     "dot" : []) []
  packagesInTopologicalOrder <- do
    case fromDot dot of
      Right graph ->
        return $ reverse $ topolocicalOrder graph
      Left message -> die message
  lookupPackages packageDB packagesInTopologicalOrder

findPackageConfigs :: Path PackageDB -> IO [FilePath]
findPackageConfigs packageDB =
  filter (".conf" `isSuffixOf`) <$> getDirectoryContents (path packageDB)

lookupPackages :: Path PackageDB -> [PackageName] -> IO [Path Package]
lookupPackages packageDB packages = do
  packageConfigs <- findPackageConfigs packageDB
  fmap catMaybes . forM packages $ \ package ->
    case lookupPackage package packageConfigs of
      Right x -> return (Path . (path packageDB </>) <$> x)
      Left message -> die message


findGlobalPackageDB :: IO (Path PackageDB)
findGlobalPackageDB = do
  output <- readProcess "ghc-pkg" ["list"] []
  return $ Path $ takeWhile (/= ':') output

registerPackage :: Path PackageDB -> Path Package -> IO ()
registerPackage packageDB package = do
  hPutStrLn stderr ("registering " ++ takeFileName (path package))
  (exitCode, out, err) <- readProcessWithExitCode "cabal"
    ("exec" :
     "--" :
     "ghc-pkg" :
     "register" :
     "--package-db" : path packageDB :
     path package :
     []) ""
  case exitCode of
    ExitSuccess -> return ()
    ExitFailure _ -> do
      hPutStrLn stderr "ghc-pkg register failed:"
      hPutStrLn stderr out
      hPutStrLn stderr err

-- * indexed paths

newtype Path a
  = Path {path :: FilePath}
  deriving (Eq, Show)

data SandboxParent
data PackageDB
data Package

-- * utils

withDirectory :: FilePath -> IO a -> IO a
withDirectory dir action = bracket start stop (const action)
 where
  start = do
    outer <- getCurrentDirectory
    createDirectoryIfMissing True dir
    setCurrentDirectory dir
    return outer
  stop = setCurrentDirectory
