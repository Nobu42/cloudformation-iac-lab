# Vimの基本設定

[vimrc](./vimrc) は、プラグインを使わずに編集するための設定。
プラグインの自動読み込みも無効にしている。Vim標準のシンタックスとインデント機能は使用する。

## 残した設定

- UTF-8、行番号、現在行の強調、括弧の対応表示。
- 折り返しなし、120桁の目安線、タブ・行末空白の表示。
- 大文字小文字を考慮する検索、入力中の検索、検索結果の強調。
- Escを2回押すと検索ハイライトを解除。
- 通常は4スペース、YAML・JSON・Shell・Terraformは2スペース。
- Pythonは4スペース、Cは幅8のタブ。
- clipboard対応ビルドの場合のみシステムクリップボードを使用。

## 外した設定

- vim-plugと全プラグインの指定、CoC補完のキーマッピング。
- Terraformプラグインの保存時フォーマット設定。
- 保存時の行末空白の自動削除。
- Ansible・Shell・Python・C・Terraformなどの実行ショートカット。
- スニペットとman表示の独自ショートカット。

標準の補完やシンタックスの対応範囲は、インストールされたVimのバージョンによって異なる。
この設定は既存のプラグインファイルを削除しない。

## まず一時的に試す

リポジトリの一番上から実行する。手元のvimrcは上書きしない。

```bash
vim -u config/vim/vimrc templates/network.yaml
```

インデントはVim内で確認できる。

```vim
:setlocal filetype? expandtab? tabstop? shiftwidth? softtabstop?
```

## macOSで通常の設定として使う場合

採用すると決めた場合だけ実行する。既存のvimrcを日時付きでバックアップしてから配置する。

```bash
if [ -f "$HOME/.vimrc" ]; then
  cp -p "$HOME/.vimrc" "$HOME/.vimrc.backup-$(date +%Y%m%d-%H%M%S)"
fi
cp config/vim/vimrc "$HOME/.vimrc"
```

新しくVimを起動して確認する。既に動いているVimでは、以前読み込んだプラグインや設定が残る場合がある。
WindowsのネイティブVimやWSLで使う場合は、Vim内の `:echo $MYVIMRC` などで実際の設定ファイルの場所を確認する。
