# Redis OSS：CloudFormation更新メモ

対象はAmazon ElastiCacheのノードベースのRedis OSS。EC2上のRedis、Serverless、Valkeyへの移行は別に扱う。
実際の更新バージョン、構成、実施順序は対象の手順書を確認する。以下は現場固有情報を含まない参照用の例。

## 1. 最初に確認するリソース

| CloudFormationの型 | 役割 |
|---|---|
| `AWS::ElastiCache::ReplicationGroup` | プライマリ・レプリカやシャードを管理する単位 |
| `AWS::ElastiCache::CacheCluster` | 個別クラスター。既存定義にこれがある場合は別途更新方法を確認 |
| `AWS::ElastiCache::SubnetGroup` | 配置先のサブネット群 |
| `AWS::ElastiCache::ParameterGroup` | エンジン用の設定 |
| `AWS::EC2::SecurityGroup` | 接続元を制限する設定 |

「1台」がノード、シャード、レプリケーショングループのどれかを先に確認する。
既存のCacheClusterを、型名だけReplicationGroupに書き換えて移行しない。

## 2. 読み方の例：YAML

これは `Resources` 以下の抜粋。単体ではデプロイできない。
参照するParametersや別リソースは省略している。既存スタックにそのまま追加せず、実際の論理IDと構成を維持して読む。

```yaml
Resources:
  RedisReplicationGroup:
    Type: AWS::ElastiCache::ReplicationGroup
    Properties:
      ReplicationGroupDescription: Learning Redis cache
      Engine: redis
      EngineVersion: !Ref RedisEngineVersion
      CacheNodeType: !Ref RedisNodeType
      CacheSubnetGroupName: !Ref RedisSubnetGroup
      CacheParameterGroupName: !Ref RedisParameterGroup
      SecurityGroupIds:
        - !Ref RedisSecurityGroup

      # One primary and one replica; cluster mode disabled.
      ClusterMode: disabled
      NumCacheClusters: 2
      AutomaticFailoverEnabled: true
      MultiAZEnabled: true

      # Keep the existing encryption and authentication design.
      AtRestEncryptionEnabled: true
      TransitEncryptionEnabled: true
      AuthToken: !Ref RedisAuthToken
```

`RedisAuthToken` は説明用の参照名。認証情報をGitやSVNに直接書かない。実際は承認済みのSecrets Manager参照やRBACなど、既存の認証設計を確認する。
暗号化や認証を有効にする作業は、エンジン更新とは分けて影響を調べる。

### JSONで同じ項目を読む例

以下は `Properties` の一部だけ。YAMLの `!Ref` はJSONでは `{"Ref": "名前"}`。

```json
{
  "Engine": "redis",
  "EngineVersion": { "Ref": "RedisEngineVersion" },
  "ClusterMode": "disabled",
  "NumCacheClusters": 2,
  "AutomaticFailoverEnabled": true,
  "MultiAZEnabled": true
}
```

## 3. 更新時によく見るプロパティ

| 項目 | 確認すること |
|---|---|
| `EngineVersion` | 承認された更新先。Parametersや外部ファイルから渡される場合もある |
| `CacheParameterGroupName` | 更新先のエンジンファミリーに適合するか |
| `NumCacheClusters` | クラスターモード無効時の合計ノード数。2ならプライマリ1＋レプリカ1 |
| `NumNodeGroups` | クラスターモード有効時のシャード数 |
| `ReplicasPerNodeGroup` | シャードごとのレプリカ数。プライマリは含めない |
| `AutomaticFailoverEnabled` | 障害時にレプリカをプライマリへ自動昇格するか |
| `MultiAZEnabled` | AZを分けた可用性構成 |
| `SnapshotRetentionLimit` | 自動バックアップの保持。更新前の手動バックアップとは区別 |
| `PreferredMaintenanceWindow` | メンテナンス時間帯。CFn変更がこの時間まで待つと決めつけない |
| `AutoMinorVersionUpgrade` | 自動更新の設定。今回明示するEngineVersion更新と区別 |

クラスターモード有効時の単純な均一構成なら、総ノード数は `シャード数 × (1 + レプリカ数)`。
`NodeGroupConfiguration` を使う既存構成もあるため、上の例に統一しない。
各プロパティの条件と更新時の扱いは[ReplicationGroup公式リファレンス](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-elasticache-replicationgroup.html)で確認する。

## 4. Auto Scalingとフェイルオーバーは別

- Auto Scaling：負荷などに応じて容量・ノード構成を調整する仕組み。
- 自動フェイルオーバー：障害時にレプリカを昇格する仕組み。

「更新前にオートスケーリングを設定する」と聞いた場合、レプリカ追加とMulti-AZ・自動フェイルオーバー有効化を指すのか、実際にスケーリングポリシーを設定するのかを確認する。
Multi-AZでは別AZのレプリカを利用する。フェイルオーバーがあってもアプリ側の再接続確認は必要。
[AWS：Multi-AZと自動フェイルオーバー](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/AutoFailover.html)

## 5. 読み取り専用の確認コマンド

macOS／Git Bash／WSL向け。値は例なので対象へ置き換える。ここで設定する変数は、このターミナル内だけで有効。

```bash
task_profile='learning'
task_region='ap-northeast-1'
task_redis_id='example-redis'
```

接続先を確認してから、対象をIDで絞る。

```bash
aws sts get-caller-identity --profile "$task_profile" --no-cli-pager
aws elasticache describe-replication-groups --replication-group-id "$task_redis_id" --profile "$task_profile" --region "$task_region" --query 'ReplicationGroups[].{ID:ReplicationGroupId,Status:Status,Failover:AutomaticFailover,MultiAZ:MultiAZ,ClusterEnabled:ClusterEnabled,Members:MemberClusters,NodeGroups:NodeGroups,Pending:PendingModifiedValues}' --output json --no-cli-pager
```

上のMemberClustersに出たIDを一つ指定し、各ノードの実際のエンジン情報を確認する。全メンバーで繰り返す。

```bash
task_cache_id='example-redis-001'
aws elasticache describe-cache-clusters --cache-cluster-id "$task_cache_id" --show-cache-node-info --profile "$task_profile" --region "$task_region" --query 'CacheClusters[].{ID:CacheClusterId,Engine:Engine,Version:EngineVersion,Status:CacheClusterStatus,ParameterGroup:CacheParameterGroup,Pending:PendingModifiedValues,Nodes:CacheNodes}' --output json --no-cli-pager
aws elasticache describe-cache-engine-versions --engine redis --profile "$task_profile" --region "$task_region" --query 'CacheEngineVersions[].{Version:EngineVersion,Family:CacheParameterGroupFamily}' --output table --no-cli-pager
```

バージョン一覧は「現在の構成からその全てへ更新できる」という意味ではない。
更新経路・パラメータの互換性・ノード対応を確認する。[AWS：エンジンバージョン管理](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/VersionManagement.html)

## 6. CloudFormationコンソールで更新するときの流れ

1. 対象スタック、論理ID、物理ID、現在のバージョン・役割・エンドポイントを記録する。
2. バックアップの取得完了、アプリの再接続、復旧先と切り替え担当を確認する。
3. レプリカ追加などの事前変更が必要なら、別作業で実施するか手順書を確認。同期完了と正常性を確認してからエンジン更新へ進む。
4. 管理元のYAML／JSON・パラメータを修正し、レビューと構文検証を行う。
5. CloudFormationコンソールで対象スタックの更新用変更セットを作成する。テンプレート差し替え／既存テンプレートとパラメータ変更のどちらかは現場の方式に合わせる。
6. 想定したリソースだけのModifyか、EngineVersionや必要な参照先だけの変更か確認。意図しないAdd／Remove／Replacementは実行前に確認する。
7. 承認後に実行し、スタックイベントとElastiCacheの状態を追う。
8. 実際のバージョン、全ノードのavailable、プライマリ・レプリカ、接続先、保留中の変更を確認する。
9. アプリ接続、読み書き、エラー率、CurrConnections、ReplicationLag、EngineCPUUtilization、メモリ、Evictionsなどを作業前と比較する。
10. 手順で要求されるドリフト／Terraform差分確認と証跡保存を行う。追加したレプリカを残すか戻すかも承認内容に合わせる。

## 7. 置換・停止・復旧で間違えないこと

- 変更セットのReplacementがFalseでも、接続断やアプリ影響がないとは限らない。No interruptionの記載だけで無停止を約束しない。
- EngineVersionを古い値へ戻しても、ダウングレードはできない。CFnのロールバックで旧エンジンへ戻れると考えない。
- 復旧には更新前スナップショットからの別構成の作成などを検討するが、対応バージョン・認証・接続先の切り替え・更新後データの扱いを事前に確認する。
- Redisを単なるキャッシュとして再作成してよいか、セッション等の保持が必要かで復旧方法が変わる。
- 暗号化設定、名前、サブネット関連など、バージョン以外の変更を一緒に入れない。置換条件はプロパティごとに確認する。
- シャード変更には `UpdatePolicy: UseOnlineResharding` など別の確認が必要。エンジン更新例へ安易に追加しない。

参照：[ReplicationGroupの更新条件](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-elasticache-replicationgroup.html)、[UpdatePolicy](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-updatepolicy.html)

## 関連メモ

- [作業前に確認する質問](./update-questions.md)
- [Git／SVNの操作](./git-svn-reference.md)
- [MariaDBのCloudFormation更新](./mariadb-cloudformation-reference.md)

例は読み方の説明用。AWSへの作成・更新による動作確認は未実施。
