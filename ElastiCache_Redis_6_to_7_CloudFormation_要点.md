# ElastiCache Redis OSS 6系から7.1への更新：CloudFormationでの作業要点

作成日：2026-10-29

今回の作業に関係するAWS公式ドキュメントの要約です。以下は調査結果と進め方の案で、既存テンプレートや実環境の確認はまだ行っていません。

## 対象作業

- CloudFormationで管理されているElastiCacheのメジャーバージョンアップ。
- Redis OSS 6.xから7.1.0を想定（AWSでの指定値は下記のとおり確認する）。
- 既存CloudFormationを基に、2シャード・レプリカ0の検証環境を作成。
- 検証環境でレプリカを増やしてバージョンアップ。
- 新しいパラメータグループを作成。
- 検証で確認が取れた後、本番環境を更新。

## 1. 今回の構成とバージョンの整理

「2シャード・レプリカ0」は、各シャードにプライマリが1台ずつある、合計2ノードの構成です。例えば、**各シャードにレプリカを1台追加すると、合計4ノード**になります。2シャードなので、クラスターモード有効の構成として確認します。

出典：[AWS：ReplicationGroup](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-elasticache-replicationgroup.html)

AWS上のRedis OSSのバージョン指定は、**`7.1.0` と決め打ちせず、`7.1` を確認対象にします。** ElastiCacheではRedis OSS 6以降、マイナーバージョンごとに提供され、パッチバージョンはAWSが管理します。現行の「6.x」についても、実際に6.0なのか6.2なのかを確認する必要があります。

出典：[AWS：バージョン管理の注意点](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/VersionManagement-upgrade-considerations.html)

## 2. 既存CloudFormationを使った検証環境の作成

今回の目的では、最初から7.1を作るだけでなく、**現行6系の構成を再現して、実際の更新手順を通す**ことが重要です。

| 確認対象 | 今回確認すること |
|---|---|
| テンプレートと実環境 | 現行バージョン、2シャード、各シャードのレプリカ数、設定差分 |
| 検証用の識別子 | スタック名、ReplicationGroupId、OutputsのExport名などの重複 |
| 接続・セキュリティ | VPC、サブネット、SG、暗号化、認証、検証アプリの接続先 |
| データ | 空の環境にテストデータを入れるか、承認済みのスナップショットを復元するか |

**テンプレートをコピーしても、Redis内のデータはコピーされません。** データも再現する場合は、バックアップから新しいクラスターに復元する方法を使います。

出典：[AWS：バックアップからの復元](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/backups-restoring.html)

## 3. レプリカ追加とバージョンアップは、段階を分けて検証する

今回の進め方として、次の順序を提案します。

1. 現行6系・2シャード・レプリカ0で検証環境を作る。
2. 更新前のアプリ動作と性能を記録する。
3. レプリカを追加し、ノードの正常性・同期状態・AZ配置を確認する。
4. 7系用パラメータグループを準備する。
5. エンジンバージョンと適用するパラメータグループを更新する。
6. アプリ動作・接続復旧・性能・データを比較する。

レプリカを追加した後は、**各シャードの別AZへの配置と、Multi-AZの実際の状態まで確認**します。レプリカ数を増やすだけで、想定した可用性構成になったとは判断しません。

出典：[AWS：Multi-AZと自動フェイルオーバー](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/AutoFailover.html)

CloudFormationでは、既存テンプレートが `ReplicasPerNodeGroup` と `NodeGroupConfiguration` のどちらで構成を指定しているかが重要です。**両者の併用によってリソース置換になる注意事項**があるため、レプリカ数だけの変更でもChange Setを確認します。

出典：[AWS：レプリカ数の更新仕様](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-elasticache-replicationgroup.html#cfn-elasticache-replicationgroup-replicaspernodegroup)

## 4. 新しいパラメータグループで確認すること

Redis OSS 7系のパラメータグループファミリーは **`redis7`** です。CloudFormationでは `AWS::ElastiCache::ParameterGroup` で作成できます。既存グループのファミリー変更は置換になるため、今回の「新規作成」という方針で、旧グループと区別して管理するのが分かりやすいです。

出典：[AWS：ParameterGroup](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-elasticache-parametergroup.html)

既存の設定は、そのまま全部転記せず、次を比較します。

- クラスターモードに関する設定。
- メモリ不足時の動作を決める `maxmemory-policy`。
- メモリ予約、タイムアウト、通知など、現場で変更している値。
- 6系から7系で削除・名称変更・デフォルト変更されたパラメータ。
- 設定変更の反映時期と、変更可能条件。

AWSはバージョン別のパラメータ差分を公開しています。**旧グループの独自設定と7系の仕様を照合する**のが、この作業の中心です。

出典：[AWS：エンジン固有パラメータ](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/ParameterGroups.Engine.html)

## 5. 検証で最も重要なのは「アプリが使い続けられるか」

AWS公式では、エンジン更新時に**既存クライアント接続が終了する**ことが明記されています。再接続・リトライ・指数バックオフの確認が必要です。Multi-AZの有無でも影響が異なり、レプリカ追加だけで無停止を保証することはできません。

出典：[AWS：アップグレード時の注意点](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/VersionManagement-upgrade-considerations.html)

今回の検証項目案は次のとおりです。

| 検証項目 | 確認内容 |
|---|---|
| 基本動作 | 読み書き、削除、TTL、実際の業務処理 |
| 更新中の影響 | 接続エラー、タイムアウト、書き込み失敗、影響時間 |
| 接続復旧 | アプリの手動再起動なしで復旧するか |
| 性能 | 更新前後の応答時間、エラー率、CPU、メモリ、レプリケーション遅延 |
| 互換性 | 使用クライアントライブラリ、Lua、ACL、Pub/Sub、使用コマンド |

例えば7系には、`STRALGO` から `LCS` への変更や、ACL・一部コマンドの戻り値の変更があります。すべてを試すのではなく、**アプリが実際に使う機能に絞って確認**します。

出典：[AWS：メジャーバージョン間の互換性変更](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/VersionManagementConsiderations.html)

## 6. 本番実施と切り戻し

**Redis OSS 7→6への直接ダウングレードはできません。** そのため、CloudFormationのテンプレートを元に戻せば復旧できる、とは考えられません。

出典：[AWS：EngineVersionの制約](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-elasticache-replicationgroup.html#cfn-elasticache-replicationgroup-engineversion)

切り戻し案は、**更新前の6系スナップショットから別の6系環境を復元し、アプリの接続先を切り替える方法**を検証対象にします。復元可能なバージョン・復旧時間・接続先変更・バックアップ取得後の書き込みの扱いまで、事前に確認が必要です。

出典：[AWS：新しい環境への復元](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/backups-restoring.html)

本番へ進む条件としては、次を決めておくと判断しやすくなります。

- 検証と本番で、更新直前の構成・更新順序をそろえる。
- Change Setで意図しない置換・削除がないことを確認する。
- 実行時刻、許容する停止時間、異常時の中止・復旧判断を決める。
- CloudFormationの更新完了に加え、ElastiCacheの状態とアプリの正常動作を確認する。

## 7. 具体的な手順に落とすための未確認事項

- 現行の正確な6系バージョン。
- 追加する各シャードのレプリカ数。
- 本番でも更新前にレプリカを追加するか。
- 既存CloudFormationのElastiCache定義。

ここが分かれば、今回の環境に合わせた変更箇所と検証項目を絞れます。
