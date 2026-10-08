# Git／GitHub・SVN コマンドメモ

CloudFormationのテンプレートを取得・修正・レビュー・登録するときに使うメモ。
例のURL、ファイル名、ブランチ名、リビジョン番号は説明用。現場の指定に置き換える。
GitHubでもSVNでもYAML・JSONの両方を管理できる。

## まず押さえる違い

Gitは履歴を管理するツール、GitHubはGitのリポジトリを共有してレビューするサービス。
ここでは普段の操作に `git` コマンド、PRの作成・レビューにはGitHubのWeb画面を使う。GitHub CLI（`gh`）は必須ではない。

| やりたいこと | Git／GitHub | SVN（Apache Subversion） |
|---|---|---|
| 初回取得 | `git clone` | `svn checkout` |
| 状態確認 | `git status` | `svn status` |
| 接続先確認 | `git remote -v` | `svn info` |
| 最新情報だけ確認 | `git fetch origin` | `svn status -u` |
| 作業ファイルを最新化 | `git pull --ff-only` | `svn update` |
| 編集内容の確認 | `git diff`、`git diff --staged` | `svn diff` |
| 新規ファイルの登録準備 | `git add` | `svn add` |
| 既存ファイルの修正を登録準備 | `git add` が必要 | `svn add` は不要 |
| 履歴へ登録 | `git commit`（手元） | `svn commit`（サーバーへ送信） |
| サーバーへ送信 | `git push` | commitで送信済み |
| 履歴を見る | `git log` | `svn log` |
| 版の識別 | コミットID | リビジョン番号（例：r1234） |

Gitは「編集 → add → commit → push」、SVNは既存ファイルなら「編集 → commit」。
GitのpushもSVNのcommitも、現場によってはCI/CDを起動する。登録とAWS反映の関係は手順書で確認する。

## 0. コマンドを打つ場所

macOSのターミナル、WindowsのGit Bash、WSLを想定。VS Code内のターミナルでもよい。
各ツールのインストールは別。Git Bashがあっても `svn` が使えるとは限らない。

```bash
git --version
svn --version --quiet
pwd
ls
```

- 基本はリポジトリ／作業コピーの一番上で操作する。
- `templates` の中からなら `cd ..` で一つ上に戻る。
- Git BashとWSLはホームディレクトリ・認証設定が異なることがある。どちらで作業しているか確認する。
- ファイル編集後は保存する。Git／SVNが見るのはエディター内の未保存内容ではなくディスク上のファイル。
- 長い履歴表示から戻れないときは `q`。下記のGit例は必要に応じて `--no-pager` を使用。
- ファイルパスの前の `--` は、そこから後がオプションではなくパスであることを示す。

## 1. Git：初回の準備

### 取得する

以下のURLは説明用。指定されたURLに置き換える。

```bash
git clone https://github.com/EXAMPLE-ORG/infra-templates.git
cd infra-templates
git remote -v
git branch --show-current
git status
```

既にclone済みなら、そのフォルダーに移動するだけ。`git init` をやり直す必要はない。
`origin` は通常clone時に付く送信先の名前、`main` はブランチ名。現場で別名なら合わせる。

### 作者情報を設定する

現場で指定された名前・メールアドレスを設定する。以下は架空の値。

```bash
git config user.name "Example User"
git config user.email "user@example.com"
git config --get user.name
git config --get user.email
```

`--global` を付けない場合、このリポジトリだけの設定。
作者情報は履歴に残る情報で、GitHubへログインするための認証情報とは別。
認証は会社指定のSSO・SSH・トークンなどを使用し、パスワードやトークンをコマンドやURLに直接埋め込まない。

## 2. Git：YAMLテンプレートを修正してPRを出す例

例：`templates/database.yaml` の承認された更新先バージョンを修正する。
下の各ブロックは段階ごとに実行し、エラーが出たら次に進まない。

### 2-1. 編集前に最新化し、作業ブランチを作る

```bash
git status
git switch main
git pull --ff-only origin main
git switch -c change/db-engine-update
```

開始時に未コミットの変更があれば、内容を確認してから進める。
`--ff-only` は履歴が分岐していたら止まる指定。自動でマージコミットを作らない。
`switch -c` は新しいブランチの作成。既存の作業ブランチへ移動するなら `git switch ブランチ名`。

### 2-2. 編集して差分を見る

VS Codeなどで対象ファイルを修正・保存する。

```bash
git status --short
git --no-pager diff -- templates/database.yaml
git diff --check
```

diffの `-` は変更前、`+` は変更後。エンジン以外に、意図しない削除・改行変更・インデント変更がないか確認する。
`diff --check` は空白などの問題を調べるもので、CloudFormationの構文・更新可否の検証ではない。

### 2-3. 対象ファイルをaddし、登録する内容を見る

```bash
git add -- templates/database.yaml
git --no-pager diff --staged
git diff --cached --check
```

ステージとは「次のコミットに入れる内容を選ぶ場所」。
`git add` の後に編集した分は、もう一度addしないとそのコミットには入らない。
`git diff --staged` と `git diff --cached` は同じ意味。
`git add .` は関係ないファイルまで含めやすいため、この例ではファイル名を指定する。

### 2-4. コミットして作業ブランチをpushする

```bash
git commit -m "RDSのエンジンバージョン指定を更新"
git push -u origin change/db-engine-update
```

`-m` はメッセージ指定。`-u` は以後のpush/pullで使う追跡先を設定する。
日本語・英語・チケット番号の書式はチームのルールに合わせる。

GitHubでPRを作り、base（取り込み先）とcompare（作業ブランチ）を確認する。
説明には変更理由、対象、検証結果、変更セットの確認結果など必要な情報を書く。
pushだけではmainに反映されない。レビュー・承認・マージ・AWS反映の順序は現場の手順に従う。

### 2-5. 送信状況を確認する

```bash
git status -sb
git log -3 --oneline
git fetch origin
git log --oneline '@{u}..HEAD'
```

最後は現在の追跡先にないローカルコミットを表示する（追跡先の設定が前提）。
GitHubの対象ブランチでもファイルとコミットを確認する。
`up to date` は最後に取得した情報との比較なので、最新状況を知るにはfetchが必要。

## 3. Git：差分・履歴の見方

| コマンド | 比較・確認の対象 |
|---|---|
| `git diff` | 未ステージの変更（作業ファイルとステージ） |
| `git diff --staged` | ステージ済みの変更（ステージとHEAD） |
| `git diff HEAD -- templates/database.yaml` | その追跡済みファイルの未コミット変更全体 |
| `git diff --stat` | 未ステージの変更量 |
| `git log -10 --oneline` | 最近のコミット |
| `git log -p -3 -- templates/database.yaml` | ファイルの直近の履歴と差分 |
| `git show HEAD:templates/database.yaml` | 最新コミットに保存されたファイル内容 |
| `git rev-parse HEAD` | 現在の完全なコミットID |

HEADは今チェックアウトしているコミット。
未追跡の新規ファイルは通常のdiffには出ない。`git status` で確認し、add後の `git diff --staged` で内容を見る。
diffが空でも「push済み」とは限らない。

`git status --short` は左列がステージ、右列が作業ファイルの状態。

```text
 M templates/database.yaml   # Modified, not staged
M  templates/database.yaml   # Staged
MM templates/database.yaml   # Edited again after staging
?? doc/check.md              # Untracked
```

上の `#` 以降は説明用で、実際のstatusには表示されない。

## 4. Git：よくあるつまずき

### 作者情報がなくcommitできない

`unable to auto-detect email address` なら作者情報を設定してcommitを再実行する。
その後push。失敗後もステージ済みの内容は通常残っている。

### Everything up-to-dateなのにファイルが更新されない

```bash
git status
git --no-pager diff
git --no-pager diff --staged
git log -3 --oneline
git remote -v
```

保存、add、commitのどこまで済んだか、送信先とブランチが合っているかを見る。
`git push main` の `main` は送信先として解釈される。送信先とブランチを指定する形は `git push origin main`。
ただし現場でmainへの直接pushが許可されているとは限らない。

### pushがfetch first／non-fast-forwardで拒否された

```bash
git fetch origin
git status
git log --oneline --graph --decorate -12
```

サーバー側に手元にない履歴がある。force pushで上書きしない。
merge／rebaseのどちらを使うかは現場のルールで確認する。
未公開の自分のコミットを載せ直す運用なら、作業ツリーを整理後、現在のブランチの正しい追跡先へ `git pull --rebase` を使う場合がある。
共有済みの履歴を無断でrebaseしない。

### 未コミットの変更を残して一時退避したい

```bash
git stash push -m "database edit before sync" -- templates/database.yaml
git stash list
git stash show -p 'stash@{0}'
```

指定ファイルの編集を退避する例。通常のstashは未追跡ファイルを含まない。
stashは手元だけにあり、pushしても別PCには届かない。
復元先のファイルと退避内容を確認してから、該当するstashを指定する。

```bash
git stash apply 'stash@{0}'
git status
git --no-pager diff
```

applyはstashを残す。競合する場合もあるので、解消と内容確認が終わるまで削除しない。

### 競合が起きた

`git status` で対象を確認し、両方の変更意図を見て編集する。
単純なテキスト競合なら `<<<<<<<`、`=======`、`>>>>>>>` などのマーカーを解消し、保存してaddする。
add後に続ける操作は状況ごとに異なる。

- rebase中：`git rebase --continue`。取りやめるなら `git rebase --abort`。
- merge中：`git merge --continue`。取りやめるなら `git merge --abort`。
- stash適用時：rebaseのcontinueは使わない。競合解消後の差分を確認して通常の作業へ戻る。

中止操作は途中の解消作業にも影響する。判断できない差分は担当者に確認する。

## 5. SVN：JSONテンプレートを修正して登録する例

### 5-1. 初回だけcheckoutする

以下は架空のURL。指定されたtrunk／branch／作業用パスに置き換える。

```bash
svn checkout https://svn.example.com/repos/infra/trunk infra-svn
cd infra-svn
svn info
```

checkoutは作業コピーの作成。SVNにはGitのステージと同じ仕組みはない。
認証は会社指定のアカウントを使い、コマンドにパスワードを直接書かない。

### 5-2. 編集前に状態とサーバー更新を確認する

```bash
svn status
svn status -u
svn update
```

`status` はローカルの変更を確認する。`status -u` はサーバーも確認するが、作業ファイルを書き換えない。
`update` は作業ファイルを更新し、編集済みならマージや競合が発生し得る。
開始時に自分のものか分からない変更があれば、そのまま更新せず確認する。

### 5-3. 既存ファイルを編集・保存して差分確認

```bash
svn status
svn diff templates/database.json
```

JSONのバージョン指定など必要箇所だけを変更する。既存ファイルの変更には `svn add` は不要。
差分確認とは別に、指定されたテンプレート検証とレビューを行う。

### 5-4. 承認後、対象ファイルを指定してcommit

```bash
svn commit templates/database.json -m "RDSのエンジンバージョン指定を更新"
```

SVNはこの時点でサーバーに反映される。別のpushはない。
`Committed revision 1234.` のような結果が出たら、その番号を記録する。
対象を省略したcommitは別の変更まで含み得るため、例ではファイルを指定する。

### 5-5. 登録後に確認

```bash
svn status
svn log -l 3 templates/database.json
svn info templates/database.json
```

statusが空でも、接続先や登録内容が正しいかは別途確認する。
SVNの作業コピーはファイルごとにリビジョンが異なることがある。フォルダーの番号だけで成果物の版を判断しない。

## 6. SVN：追加・履歴・状態表示

### 新しいファイルを追加する場合

エディターでファイルを作成・保存してから実行する。

```bash
svn add templates/cache.json
svn diff templates/cache.json
svn commit templates/cache.json -m "キャッシュ用テンプレートを追加"
```

`svn add` は新規ファイルの管理開始を予約する操作。Gitのaddのように編集内容を固定するステージではない。

### 過去の内容を見る

以下の番号は例。実際のリビジョン番号に置き換える。

```bash
svn log -l 10 templates/database.json
svn diff -c 1234 templates/database.json
svn cat -r 1234 templates/database.json
```

`diff -c 1234` はr1233からr1234への変更、`cat -r 1234` は指定版の内容表示。作業ファイルは戻さない。
ファイルの移動・削除をまたぐ履歴では、URLやpeg revisionの指定が必要になることがある。

### statusの主な記号

| 表示 | 意味 |
|---|---|
| `M` | 内容変更（プロパティ変更は別の列） |
| `A` | 追加予定 |
| `D` | 削除予定 |
| `?` | 管理対象外 |
| `!` | 管理対象だがファイルが見つからない、または不完全な作業コピー |
| `C` | 競合。内容・プロパティ・ツリー競合で表示列が異なる |
| `*`（`status -u`） | サーバー側に新しい変更あり |

### out of dateでcommitできない

他の人の変更が入っている可能性がある。手元の差分を確認したうえで `svn update` し、更新後の差分を再確認する。
競合や変更内容の増加があれば再レビューしてからcommitする。

### テキスト競合を解消する場合

`svn status` と `svn diff` で確認し、エディターで両者の意図を反映する。
内容を正しく直して保存した後にだけ、解決済みとして登録する。

```bash
svn resolve --accept working templates/database.json
svn diff templates/database.json
```

このresolveは自動で正しい内容を作るコマンドではない。編集済みの作業ファイルを解決結果として採用する。
ツリー競合（削除・移動など）に同じ手順を機械的に当てはめず、担当者と方針を確認する。

## 7. 取り消し操作は意味を分ける

以下は目的を理解したときだけ使用する。

| コマンド例 | 何が起きるか |
|---|---|
| `git restore --staged -- templates/database.yaml` | ステージから外す。作業ファイルの編集は残る |
| `git restore --worktree -- templates/database.yaml` | 作業ファイルをステージの内容に戻す。未ステージの編集は失われる |
| `git revert COMMIT_ID` | 指定コミットを打ち消す新しいコミットを作る。共有履歴を書き換えない |
| `svn revert templates/database.json` | 作業コピーの未コミット変更を破棄する。サーバーのコミットを取り消す操作ではない |

特に `git revert` と `svn revert` は同じ意味ではない。
`git reset --hard`、`git clean -fd`、force push、`svn revert -R .` をエラー解消のために安易に使わない。
コードを戻してもAWS環境が自動で元に戻るとは限らない。DBの復旧は別の作業手順として扱う。

## 8. CloudFormation更新時に残す記録

- 対象テンプレートのパス、対象ブランチ／SVNのURL。
- 更新前後のGitコミットID／SVNのリビジョン番号。
- レビュー・承認の記録と、実行した変更セット。
- 検証結果と更新後確認の結果。

登録した版と実際にデプロイするファイルが一致しているか確認する。
push／commitから自動デプロイされる現場では、実行タイミングを手順書に合わせる。
公開リポジトリには認証情報、Terraform state、社内テンプレートや証跡を追加しない。

## 9. MacとWindowsで同じ学習リポジトリを使う場合

作業を終えるPCで差分を確認し、必要なファイルだけcommit・pushする。
次のPCでは編集前に状態を確認してpullする。

```bash
cd ~/cloudformation-iac-lab
git status
git pull --ff-only origin main
```

未コミットの編集やstashは別PCに自動では移らない。
両方で同じファイルを同時編集しない。片方からのpushが終わってから、もう片方でpullする。
改行コードだけで全行が変更されて見える場合は、既存の `.gitattributes` やエディター設定を確認する。
原因を確認せず、全体の改行変換やグローバル設定変更をしない。

## 参照先

- [Git：コマンド一覧](https://git-scm.com/docs)
- [Git：pull](https://git-scm.com/docs/git-pull)
- [Git：diff](https://git-scm.com/docs/git-diff)
- [Git：stash](https://git-scm.com/docs/git-stash)
- [Git：restore](https://git-scm.com/docs/git-restore)
- [Git：revert](https://git-scm.com/docs/git-revert)
- [GitHub：PRの作成](https://docs.github.com/en/pull-requests/how-tos/create-pull-requests/creating-a-pull-request)
- [Apache Subversion：ドキュメント](https://subversion.apache.org/docs/)
- [Version Control with Subversion：基本の作業手順（1.8版）](https://svnbook.red-bean.com/en/1.8/svn.tour.cycle.html)

端末に入っている版の詳細は `git help コマンド名`、`svn help コマンド名` でも確認できる。
