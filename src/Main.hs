{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use &&" #-}

-- |
-- Copyright : Herbert Valerio Riedel
-- License   : GPLv3
--
module Main where

import           Common

import           Control.Lens
import           Conduit
import qualified Amazonka
import qualified Amazonka.Auth
import           Amazonka.Data (toText)
import qualified Amazonka.S3
import           Amazonka.S3.ListObjectsV2
import           Amazonka.S3.PutObject
import           Amazonka.S3.Types.Object
import           Control.Concurrent.Async
import           Control.Concurrent.MVar
import           Control.Exception
import           Control.Monad
import qualified Data.ByteString          as BS
import qualified Data.ByteString.Short    as BSS
import qualified Data.HashMap.Strict      as HM
import           Data.String
import qualified Data.Text                as T
import qualified Data.Text.Encoding       as T
import           Data.Time.Clock.POSIX    (getPOSIXTime)
import           Network.Http.Client
import           Options.Applicative      as OA
import           System.Environment       (getEnv)
import           Text.Read (readMaybe)

import           IndexClient
import           IndexShaSum              (IndexShaEntry (..))
import qualified IndexShaSum
import           System.Exit

----------------------------------------------------------------------------

getSourceTarball :: URL -> ShortByteString -> IO (Either Int ByteString)
getSourceTarball hackagePackageUri pkgname = do
    -- putStrLn ("fetching " <> show pkgname <> " ...")
    t0 <- getPOSIXTime
    resp <- try $ get (hackagePackageUri <> BSS.fromShort pkgname) concatHandler'
    t1 <- getPOSIXTime
    case resp of
        Right pkgdat -> do
            logMsg DEBUG ("downloaded " <> show pkgname <> "; dt=" ++ show (t1-t0) ++ " size=" ++ show (BS.length pkgdat))
            return (Right pkgdat)

        Left e@(HttpClientError code _) -> do
            logMsg WARNING ("failed to get " <> show pkgname <> " with " <> show e)
            return (Left code)

----------------------------------------------------------------------------
-- CLI

data Opts = Opts
    { optDryMode       :: Bool
    , optForceSync     :: Bool
    , optHackageUrl    :: String
    , optHackagePkgUrl :: String
    , optS3BaseUrl     :: String
    , optS3BucketId    :: Amazonka.S3.BucketName
    , optMaxConns      :: Word
    }

getOpts :: IO Opts
getOpts = execParser opts
  where
    opts = info (helper <*> parseOpts)
           (fullDesc <> header "Hackage mirroring tool"
                     <> footer fmsg
           )

    parseOpts = Opts <$> switch (long "dry" <> help "operate in read-only mode")
                     <*> switch (long "force-sync" <> help "force a full sync even when meta-data appears synced")
                     <*> strOption (long "hackage-url" <> value "http://hackage.haskell.org"
                                    <> metavar "URL"
                                    <> help "URL used to retrieve Hackage meta-data" <> showDefault)
                     <*> strOption (long "hackage-pkg-url" <> value "http://hackage.haskell.org/package/"
                                    <> metavar "URL"
                                    <> help "URL used to retrieve Hackage package tarballs" <> showDefault)
                     <*> strOption (long "s3-base-url" <> value "https://objects-us-west-1.dream.io"
                                    <> metavar "URL"
                                    <> help "Base URL of S3 mirror bucket" <> showDefault)
                     <*> (Amazonka.S3.BucketName . T.pack <$> strOption (long "s3-bucket-id" <> value "hackage-mirror"
                                    <> help "id of S3 mirror bucket" <> showDefault))
                     <*> OA.option auto (long "max-connections" <> metavar "NUM" <> value 1
                                    <> help "max concurrent download connections" <> showDefault)


    fmsg = "Credentials are set via 'S3_ACCESS_KEY' & 'S3_SECRET_KEY' environment variables"


main :: IO ()
main = do
    Opts{..} <- getOpts

    let s3cfgBaseUrl   = fromString optS3BaseUrl
    s3cfgAccessKey <- fromString <$> getEnv "S3_ACCESS_KEY"
    s3cfgSecretKey <- fromString <$> getEnv "S3_SECRET_KEY"

    awsEnv <- do
        e <- Amazonka.newEnv (pure . Amazonka.Auth.fromKeys s3cfgAccessKey s3cfgSecretKey)
        let s3 = Amazonka.setEndpoint True s3cfgBaseUrl 443 Amazonka.S3.defaultService
        pure $ Amazonka.configureService s3 e

    try (main2 (Opts{..}) awsEnv optS3BucketId) >>= \case
        Left e   -> do
            logMsg CRITICAL ("exception: " ++ displayException (e::SomeException))
            exitFailure
        Right ExitSuccess -> do
            logMsg INFO "exiting"
            exitSuccess
        Right (ExitFailure rc) -> do
            logMsg ERROR ("exiting (code = " ++ show rc ++ ")")
            exitWith (ExitFailure rc)

pathToObjKey :: Path Unrooted -> Amazonka.S3.ObjectKey
pathToObjKey = Amazonka.S3.ObjectKey . T.pack . toUnrootedFilePath

sbsToObjKey :: ShortByteString -> Amazonka.S3.ObjectKey
sbsToObjKey = Amazonka.S3.ObjectKey . T.decodeUtf8 . BSS.fromShort

main2 :: Opts -> Amazonka.Env -> Amazonka.S3.BucketName -> IO ExitCode
main2 Opts{..} awsEnv bucketId = handle pure $ do
    when optDryMode $
        logMsg WARNING "--dry mode active"

    -- used for index-download
    let hackageUri = fromMaybe (error "hackageUri") $ parseURI optHackageUrl


    repoCacheDir <- makeAbsolute (fromFilePath "./index-cache/")

    indexChanged <- updateIndex hackageUri repoCacheDir
    case indexChanged of
        HasUpdates -> logMsg INFO "index changed"
        NoUpdates  -> logMsg INFO "no index changes"

    let indexTarFn = fragment "01-index.tar.gz"
        jsonFiles  = [ fragment "mirrors.json"
                     , fragment "root.json"
                     , fragment "snapshot.json"
                     , fragment "timestamp.json"
                     ]

    -- check meta-data files first to detect if anything needs to be done
    logMsg INFO "fetching meta-data file objects from S3..."
    -- Meta files are the ones at the top level of the hierarchy, which is what
    -- this query returns.
    let getMetaFiles = newListObjectsV2 bucketId & listObjectsV2_delimiter ?~ '/'
    metafiles <- sinkObjectMap awsEnv getMetaFiles
    metadirties <- forM jsonFiles $ \fn -> do
        objdat <- readStrictByteString (repoCacheDir </> fn)

        let obj_md5 = md5hash objdat
            obj_sz  = BS.length objdat
            objkey  = pathToObjKey fn
        let dirty = case HM.lookup objkey metafiles of
                Nothing -> True
                Just (omiMD5, omiSize) -> not (omiMD5 == obj_md5 && omiSize == obj_sz)

        pure dirty

    unless (optForceSync || or metadirties) $ do
        -- NB: 01-index.tar.gz is not compared
        logMsg INFO "meta-data files are synced and '--force-sync' was not given; nothing to do"
        exitSuccess

    logMsg INFO "Dirty meta-files detected, doing full sync."

    (idx,missing) <- IndexShaSum.run (IndexShaSum.IndexShaSumOptions True (repoCacheDir </> indexTarFn) Nothing)
    let idxBytes = sum [ fromIntegral sz | IndexShaEntry _ _ _ sz <- idx, sz >= 0 ] :: Word64

    forM_ missing $ \n -> do
      logMsg CRITICAL ("Package " ++ show n ++ " missing SHA256 sum!")

    logMsg INFO ("Hackage index contains " <> show (length idx) <> " src-tarball entries (" <> show idxBytes <> " bytes)")

    logMsg INFO "Listing all S3 objects (may take a while) ..."
    bucketObjects <- sinkObjectMap awsEnv (newListObjectsV2 bucketId)

    let s3cnt = length (filter isSrcTarObjKey (HM.keys bucketObjects))
    logMsg INFO ("S3 index contains " <> show s3cnt <> " src-tarball entries (total " <> show (HM.size bucketObjects) <> ")")

    idxQ <- newMVar idx

    -- fire up some workers...
    mapConcurrently_ (worker idxQ bucketObjects awsEnv) [1..optMaxConns]
    logMsg INFO "workers finished..."

    -- update meta-data last...
    -- this one can take ~1 minute; so we need to update this first
    do tmp <- readStrictByteString (repoCacheDir </> indexTarFn)
       syncFile bucketObjects tmp (pathToObjKey indexTarFn) awsEnv

    forM_ jsonFiles $ \fn -> do
        tmp <- readStrictByteString (repoCacheDir </> fn)
        syncFile bucketObjects tmp (pathToObjKey fn) awsEnv

    logMsg INFO "sync job completed"

    unless (null missing) $
      fail ("Encountered " ++ show (length missing) ++ " package(s) with missing SHA256 sum")

    return ExitSuccess
  where
    isSrcTarObjKey (Amazonka.S3.ObjectKey k') =
        and [ T.isPrefixOf "package/" k'
            , T.isSuffixOf ".tar.gz" k'
            , T.count "/" k' == 1
            ]


    s3PutObject' :: Amazonka.Env -> Word -> ByteString -> Amazonka.S3.ObjectKey -> IO ()
    s3PutObject' env thrId objdat objkey = do
        t0 <- getPOSIXTime
        if optDryMode
            then logMsg WARNING "no-op due to --dry"
            else void $ runResourceT $ Amazonka.send env putObj
        t1 <- getPOSIXTime
        logMsg DEBUG ("PUT completed; thr=" <> show thrId <> " dt=" ++ show (t1-t0))
      where
        objkeyTxt = objkey ^. Amazonka.S3._ObjectKey
        ctype = case () of
            -- While suspect, these choices are copied faithfully from earlier
            -- versions of this tool.
            -- Suspicions:
            -- 1) x-gzip should probably be a Content-Encoding instead of
            --    Content-Type. (At the very least, it should be
            --    application/gzip, per https://www.rfc-editor.org/rfc/rfc6713.)
            --    See https://www.rfc-editor.org/rfc/rfc9110#name-content-encoding .
            -- 2) application/binary should really be application/octet-stream.
            --    The latter is the standardized name for "any old thing".
            --    See https://www.rfc-editor.org/rfc/rfc2046#section-4.5.1 .
            _ | ".gz"   `T.isSuffixOf` objkeyTxt -> "application/x-gzip"
            _ | ".json" `T.isSuffixOf` objkeyTxt -> "application/json"
            _ -> "application/binary"
        putObj =
            Amazonka.S3.newPutObject bucketId objkey (Amazonka.toBody objdat)
                & putObject_contentType ?~ ctype



    syncFile bucketObjects objdat objkey conn = do
        let obj_md5 = md5hash objdat
            obj_sz  = BS.length objdat
        let dirty = case HM.lookup objkey bucketObjects of
                Nothing -> True
                Just (omiMD5, omiSize) -> not (omiMD5 == obj_md5 && omiSize == obj_sz)
        if dirty
           then logMsg INFO  (show objkey ++ " needs sync")
           else logMsg DEBUG (show objkey ++ " is up-to-date")

        when dirty $ s3PutObject' conn 0 objdat objkey


    worker idxQ bucketObjects conn thrId = do
        indexEntry <- modifyMVar idxQ (pure . popQ)
        case indexEntry of
            Nothing -> return () -- queue empty, terminate worker
            Just (IndexShaEntry pkg s256 m5 sz) -> do
                let key = sbsToObjKey ("package/" <> pkg)
                case HM.lookup key bucketObjects of
                    Nothing -> do -- miss
                        resp <- getSourceTarball (fromString optHackagePkgUrl) pkg
                        case resp of
                            Right pkgdat -> do
                                let s256' = sha256hash pkgdat
                                    m5'   = md5hash pkgdat

                                unless (BS.length pkgdat == sz) $
                                    fail ("size mismatch (expected: " ++ show sz ++ ")")
                                unless (s256 == s256') $
                                    fail "sha256 mismatch"
                                unless (m5 == m5') $
                                    fail "md5 mismatch"

                                s3PutObject' conn thrId pkgdat key

                            Left _ -> logMsg WARNING "**skipping**" -- TODO: collect


                    Just bucketObject@(omiMD5, _) -> do -- hit
                        if omiMD5 == m5
                            then pure () -- OK
                            else do
                              logMsg CRITICAL "MD5 corruption"
                              fail ("MD5 corruption " ++ show indexEntry ++ "  " ++ show bucketObject)
                        return ()
                -- loop
                worker idxQ bucketObjects conn thrId
      where
        popQ []     = ([],Nothing)
        popQ (x:xs) = (xs, Just x)

sinkObjectMap :: Amazonka.Auth.Env -> ListObjectsV2 -> IO (HashMap Amazonka.S3.ObjectKey (MD5Val, Int))
sinkObjectMap awsEnv query = runResourceT $ runConduit
    $ Amazonka.paginate awsEnv query
    .| mapC (^. listObjectsV2Response_contents)
    .| concatMapC (fromMaybe [])
    .| foldMapC objectToHMap

-- | The MD5Val comes from the Object's ETag, although that isn't guaranteed to
-- be an MD5 sum! IMHO we should not be using it as a hash but as an opaque
-- value that simply changes whenever the contents of the object change.
-- Comparing it against our own calculated hash, which we do above, is certain
-- to run into issues eventually.
objectToHMap :: Object -> HM.HashMap Amazonka.S3.ObjectKey (MD5Val, Int)
objectToHMap o =
    HM.singleton
        (o ^. object_key)
        (fromMaybe md5zero
            ( (md5unhex <=< readMaybe)
                (T.unpack (toText (Amazonka.S3.fromETag (o ^. object_eTag)))))
            , fromIntegral (o ^. object_size))

----------------------------------------------------------------------------
