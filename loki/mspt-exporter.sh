#!/bin/bash
jolokia_url="http://$1/jolokia/read/net.minecraft.server:type=Server"
jolokia_host=$1
loki_url="http://loki.nuc.home.arpa:3100/loki/api/v1/push"

if [ -z "$jolokia_host" ] ; then
  exit 1
fi

response=`curl --silent --location --request GET $jolokia_url`

payload=$(jq -n --arg jolokia_host $jolokia_host \
  --arg timestamp "$(echo $response | jq -r '.timestamp')000000000" \
  --arg averageTickTime "$(echo $response | jq -r '.value.averageTickTime')" '
  {
    "streams": [
      {
        "stream": { "jolokia_host": $jolokia_host },
        "values": [ [$timestamp, $averageTickTime] ]
      }
    ]
  }
')
echo $payload

curl -X POST -H "Content-Type: application/json" -d "$payload" "$loki_url"
