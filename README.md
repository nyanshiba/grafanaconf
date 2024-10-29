## Loki

### as1s-beacon-scanner.sh

旭化成 3密見える化センサの温度, 湿度, CO2値をGrafanaに表示するために、BLEビーコンをスキャンしてLokiに送るシェルスクリプト。  
[3密見える化センサのCO2値をプッシュ通知する - 俺の外付けHDD](https://nyanshiba.com/blog/co2-via-ble/#bluetoothctl)

### mspt-exporter.sh

MinecraftのMSPTを取得するシェルスクリプト。

### oura-exporter.ps1

[Oura API V2](https://cloud.ouraring.com/v2/docs#operation/Multiple_daily_readiness_Documents_v2_usercollection_daily_readiness_get)を叩いて整形してLokiに送るPowerShellスクリプト。

### sflow-collector.sh

NEC IX2000/3000シリーズのsFlow フローサンプルをGrafanaに表示するために、sFlow Collectorとして振る舞うシェルスクリプト。  
