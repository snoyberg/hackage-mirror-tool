#!/usr/bin/env bash

set -eux

mkdir -p $HOME/workdir/logs
cd $HOME/workdir/

source /secret/config.sh

export S3_ACCESS_KEY=$AWS_ACCESS_KEY_ID
export S3_SECRET_KEY=$AWS_SECRET_ACCESS_KEY

while true
do
    timeout -k5 15m /usr/local/bin/hackage-mirror-tool +RTS -t -A2M -M256M -RTS \
      --hackage-url      $HACKAGE_URL \
      --hackage-pkg-url  $HACKAGE_URL/package/ \
      --s3-base-url      https://s3.amazonaws.com \
      --s3-bucket-id     $S3_BUCKET

    sleep 5m
done
