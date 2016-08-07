#!/bin/sh

NAME=$1
VERSION=$2
ZIP=${NAME}_${VERSION}

cd prometheus
git archive --format=zip --prefix=$ZIP/prometheus/ -o ../prometheus-client.zip  HEAD 
cd ../$NAME
git archive --format=zip --prefix=$ZIP/ -o ../$ZIP.zip  HEAD  .
cd ..
unzip prometheus-client.zip
rm prometheus-client.zip
zip -m -g -r $ZIP.zip $ZIP/prometheus
rmdir $ZIP
