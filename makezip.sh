#!/bin/sh

# jq comes from https://stedolan.github.io/jq/download (or apt install it).
NAMES='promfacto '`git config --file .gitmodules --get-regexp path | awk '$2 != "prometheus" { print $2 }'`

for NAME in $NAMES; do
    cd $NAME
    VERSION=`jq -r '.version' info.json`
    ZIP=${NAME}_${VERSION}

    git archive --format=zip --prefix=$ZIP/ -o ../$ZIP.zip  HEAD  .
    cd ../prometheus
    git archive --format=zip --prefix=$ZIP/prometheus/ -o ../prometheus-client.zip  HEAD 

    cd ..
    unzip prometheus-client.zip
    rm prometheus-client.zip
    zip -m -g -r $ZIP.zip $ZIP/prometheus
    rmdir $ZIP
done
