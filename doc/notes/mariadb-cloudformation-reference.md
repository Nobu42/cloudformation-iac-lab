# RDS for MariaDB：CloudFormation更新メモ

対象はAmazon RDS for MariaDBのDBインスタンス。Aurora MySQLやRDS for MySQLの手順とは分けて確認する。
具体的なバージョンは手順書と対象リージョンで確認する。以下は現場固有情報を含まない参照用の例。

## 1. テンプレートで見る場所

| CloudFormationの型 | 役割 |
|---|---|
| `AWS::RDS::DBInstance` | DBインスタンス本体。Engineはmariadb |
| `AWS::RDS::DBSubnetGroup` | DBを配置するサブネット群 |
| `AWS::RDS::DBParameterGroup` | DBエンジンの設定。Familyが更新先と合うか確認 |
| `AWS::RDS::OptionGroup` | 利用する追加機能の設定。使っている場合に確認 |
| `AWS::EC2::SecurityGroup` | 接続元を制限する設定 |

Multi-AZのスタンバイと、読み取り用のリードレプリカは役割が異なる。
「1台」という呼び方だけで判断せず、DB識別子と複製関係を確認する。

## 2. 読み方の例：YAML

以下は `Resources` 以下の抜粋。Parametersやネットワークリソースは省略しており、単体ではデプロイできない。
例の値を既存DBへまとめて適用しない。更新時は既存の論理ID・設定を保ち、承認された差分だけを修正する。

```yaml
Resources:
  MariaDB:
    Type: AWS::RDS::DBInstance
    DeletionPolicy: Snapshot
    UpdateReplacePolicy: Snapshot
    Properties:
      Engine: mariadb
      EngineVersion: !Ref MariaDBEngineVersion
      DBInstanceClass: !Ref DatabaseInstanceClass
      AllocatedStorage: '20'
      StorageType: gp3
      StorageEncrypted: true
      DBSubnetGroupName: !Ref DatabaseSubnetGroup
      VPCSecurityGroups:
        - !Ref DatabaseSecurityGroup
      DBParameterGroupName: !Ref MariaDBParameterGroup

      # Example only; preserve the approved availability design.
      MultiAZ: true
      PubliclyAccessible: false
      BackupRetentionPeriod: 7
      DeletionProtection: true

      # Manage the master password in Secrets Manager.
      MasterUsername: !Ref DatabaseAdminUser
      ManageMasterUserPassword: true

      # A minor upgrade example, not a major upgrade procedure.
      AllowMajorVersionUpgrade: false
      AutoMinorVersionUpgrade: false
```

管理パスワード方式は例。既存のSecrets Manager、動的参照、認証方式を更新時に勝手に変更しない。
`ManageMasterUserPassword: true` と `MasterUserPassword` を併記しない。

### JSONで同じ項目を読む例

以下は `Properties` の一部。JSONには通常のコメントを書かず、説明は別のメモに残す。

```json
{
  "Engine": "mariadb",
  "EngineVersion": { "Ref": "MariaDBEngineVersion" },
  "AllowMajorVersionUpgrade": false,
  "AutoMinorVersionUpgrade": false,
  "MultiAZ": true
}
```

## 3. バージョン更新時に見る項目

| 項目 | 確認すること |
|---|---|
| `EngineVersion` | 更新先。Parameters等で渡される場合はその値も確認 |
| `AllowMajorVersionUpgrade` | メジャー更新を許可する設定。trueにするだけでは更新されない |
| `AutoMinorVersionUpgrade` | 自動マイナー更新の設定。明示的なEngineVersion変更とは別 |
| `DBParameterGroupName` | 更新先のFamily・独自設定・再起動要否 |
| `OptionGroupName` | オプショングループ利用時のエンジン・メジャー互換性 |
| `ApplyImmediately` | 更新の適用タイミング。保留中の別の変更への影響も確認 |
| `PreferredMaintenanceWindow` | メンテナンス時間帯。これだけで更新時刻を判断しない |
| `BackupRetentionPeriod` | 自動バックアップ保持。作業前バックアップ取得の確認とは別 |
| `MultiAZ` | 可用性構成。エンジン更新の停止時間がゼロになる設定ではない |
| `DeletionProtection` | DB削除の防止。更新の停止・誤設定・データ変更を防ぐ機能ではない |

対応する属性と更新影響は[DBInstance公式リファレンス](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-rds-dbinstance.html)で確認する。

### 適用タイミングは実行前に確認

調査時点の公式リファレンスには `ApplyImmediately` があり、既定値はtrueと記載されている。
falseでは次のメンテナンス時間帯への保留となる変更があり、実環境への適用まで設定差分が残り得る。
既存テンプレート・対象リージョンでの対応・変更種別・保留中の変更を確認し、作業時刻を決める。
このメモの例には適用タイミングを固定で追加していない。現場の指定を確認せず新しいプロパティを足さない。

## 4. 読み取り専用の確認コマンド

macOS／Git Bash／WSL向け。以下の識別子とバージョンは対象に置き換える。

```bash
task_profile='learning'
task_region='ap-northeast-1'
task_db_id='example-mariadb'
```

```bash
aws sts get-caller-identity --profile "$task_profile" --no-cli-pager
aws rds describe-db-instances --db-instance-identifier "$task_db_id" --profile "$task_profile" --region "$task_region" --query 'DBInstances[].{ID:DBInstanceIdentifier,Engine:Engine,Version:EngineVersion,Status:DBInstanceStatus,MultiAZ:MultiAZ,Endpoint:Endpoint,Pending:PendingModifiedValues,ParameterGroups:DBParameterGroups,OptionGroups:OptionGroupMemberships,ReplicaSource:ReadReplicaSourceDBInstanceIdentifier,Replicas:ReadReplicaDBInstanceIdentifiers,BackupDays:BackupRetentionPeriod}' --output json --no-cli-pager
```

更新可能なバージョンは、現在のEngineVersionを指定して調べる。

```bash
task_current_version='REPLACE_WITH_CURRENT_VERSION'
aws rds describe-db-engine-versions --engine mariadb --engine-version "$task_current_version" --profile "$task_profile" --region "$task_region" --query 'DBEngineVersions[].ValidUpgradeTarget[].{Version:EngineVersion,Major:IsMajorVersionUpgrade}' --output table --no-cli-pager
```

指定したバージョンが正しいか、結果が空の場合も含めて確認する。手動で数字を大きくすれば更新できるわけではない。
[AWS：MariaDBの更新先確認](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.MariaDB.html)

更新先のパラメータファミリーを調べる例。

```bash
task_target_version='REPLACE_WITH_APPROVED_TARGET_VERSION'
aws rds describe-db-engine-versions --engine mariadb --engine-version "$task_target_version" --profile "$task_profile" --region "$task_region" --query 'DBEngineVersions[].{Version:EngineVersion,Family:DBParameterGroupFamily}' --output table --no-cli-pager
```

## 5. 更新順序とアプリ影響

- マイナー更新でも、アプリの接続確認と停止時間の調整は必要。
- RDS for MariaDBでリードレプリカを使う場合は、ソースより先に全リードレプリカを更新する。
- Multi-AZのDBインスタンスでもエンジン更新時には停止が発生する。スタンバイがあるから無停止とは考えない。
- メジャー更新は有効な更新経路、パラメータ／オプショングループ、SQL・文字コード・認証・ドライバー等の互換性を確認する。

参照：[MariaDBのアップグレード](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.MariaDB.html)、[メジャーバージョン更新](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_UpgradeDBInstance.MariaDB.Major.html)

## 6. CloudFormationコンソールでの作業の流れ

1. 対象アカウント、リージョン、スタック、論理ID、DB識別子を照合する。
2. 現在のバージョン、パラメータ、構成、保留中の変更、アプリ正常性を記録する。
3. 作業前バックアップの完了と、復旧方法・接続先切り替え担当を確認する。
4. 管理元のJSON／YAMLとパラメータを修正する。現在の論理IDを変えず、無関係な差分を混ぜない。
5. テンプレートの検証、レビュー、Git／SVNへの登録を現場の順序に従って行う。
6. CloudFormationコンソールから更新用変更セットを作成する。取り込む版とパラメータの値を確認する。
7. 想定したDBのModifyであること、Replacement、詳細なプロパティ差分を確認する。意図しないDBの作成・削除・置換があれば実行前に止めて確認する。
8. 承認後、指定時間に実行。CloudFormationイベントとRDSイベントを追う。
9. スタック結果だけでなく、実際のEngineVersion、available、PendingModifiedValues、パラメータ適用状態を確認する。
10. アプリの読み書き、再接続、ログ、DatabaseConnections、CPUUtilization、FreeableMemory、FreeStorageSpace、ReadLatency／WriteLatency等を比較する。
11. ドリフトやTerraform差分など、指定された更新後確認を行い、変更セット・コミット／リビジョン・検証結果を記録する。

ReplacementがFalseでも、停止がないという意味ではない。
`UPDATE_COMPLETE` だけでアプリ正常性や、保留した変更の適用まで確認できたとは扱わない。

## 7. 削除ポリシーと復旧は別に考える

| 設定 | 主に作用する場面 |
|---|---|
| `DeletionPolicy: Snapshot` | スタック削除やテンプレートからリソースを除くとき |
| `UpdateReplacePolicy: Snapshot` | 更新で置換される旧リソースを扱うとき |
| `BackupRetentionPeriod` | 自動バックアップの保持 |
| 更新前の手動スナップショット | 作業手順として取得・完了確認する復旧用バックアップ |

DeletionPolicy／UpdateReplacePolicyはTypeと同じ深さで書き、Properties内には入れない。
インプレースのエンジン更新前に必ずスナップショットを取る指示として、これらのポリシーを使うことはできない。
[DeletionPolicy](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-deletionpolicy.html)、[UpdateReplacePolicy](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-updatereplacepolicy.html)

更新後にEngineVersionを古い値へ戻してもダウングレードできない。
復旧は更新前スナップショットから別DBを復元する方法などを事前に決める。復元時のネットワーク・暗号鍵・パラメータ、接続先の切り替え、更新後に書き込まれたデータの扱いまで確認する。
CloudFormationのロールバックと、DBエンジン／データの復旧を同じものと考えない。

## 関連メモ

- [作業前に確認する質問](./update-questions.md)
- [Git／SVNの操作](./git-svn-reference.md)
- [Redis OSSのCloudFormation更新](./redis-cloudformation-reference.md)

例は読み方の説明用。AWSへの作成・更新による動作確認は未実施。
