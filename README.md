# LANraragi plugins for Speaker Deck

Speaker Deck の公開投稿を LANraragi に取り込む Downloader と Metadata プラグインです。

- 元 PDF のダウンロードリンクがあれば、PDF を変更せず保存します。
- PDF リンクがない公開投稿は、公開プレイヤーの閲覧用画像を順番に取得して CBZ にします。
- PDF リンクがあるのに取得が失敗した場合はエラーにします。CBZ への切り替えは行いません。
- タイトル、説明、投稿者アカウント、公開日、カテゴリ、明示された言語、元 URL を取得します。

対応範囲はログイン不要の個別投稿 URL (`https://speakerdeck.com/author/deck`) です。
認証、パスワード付き投稿、投稿者単位の一括取得、文字起こしの保存は対象外です。

## インストール

LANraragi 0.9.82 のプラグイン仕様を対象にしています。Perl 5.36 以降と、LANraragi が同梱する
Mojolicious、Archive::Zip を利用し、追加の外部コマンドは必要ありません。

LANraragi を停止し、このリポジトリの次のファイルを LANraragi インストール先の同じ相対パスへコピーしてください。

```text
lib/LANraragi/Plugin/Download/SpeakerDeck.pm
lib/LANraragi/Plugin/Metadata/SpeakerDeck.pm
lib/LANraragi/Utils/SpeakerDeck.pm
```

共通モジュールも必要なため、Web UI からプラグイン2ファイルをサイドロードするだけでは動作しません。
Docker では3ファイルをイメージへ追加するか、インストール先の各ファイルへ読み取り専用で
バインドマウントしてください。更新時も3ファイルをまとめて差し替えて再起動します。

再起動後、プラグイン設定で **Speaker Deck Downloader** と **Speaker Deck Metadata** が表示されることを確認します。
新規取得時のメタデータ付与には、Speaker Deck Metadata の自動実行を有効にしてください。
タイトルも更新する場合は、LANraragi 側の「プラグインによるタイトル変更」の設定を有効にします。

## 使い方

LANraragi のダウンロード画面に投稿 URL を入力します。`?slide=2` や `#3` などのスライド指定は除いて取得します。
保存ファイル名は `speakerdeck_{投稿ID}.pdf` または `.cbz` です。

LANraragi 本体が元 URL を `source:` タグとして登録するので、Metadata プラグインがこのタグを読んで投稿を特定します。
既存アーカイブにも、Speaker Deck の `source:` タグを付けて実行できます。
単発引数に投稿 URL を入力すると、その実行だけ既存タグより優先します。
異なる投稿の `source:` が複数ある場合は、単発引数で投稿を指定してください。
Speaker Deck の URL がないアーカイブに対する自動実行は、通信せず終了します。

| 取得情報 | LANraragi の項目 |
| --- | --- |
| 投稿タイトル | タイトル |
| 投稿の説明文 | Summary（HTML を除去） |
| 提供元 | `provider:speakerdeck` |
| 正規化した投稿 URL | `source:https://speakerdeck.com/author/deck` |
| 投稿者アカウント | `author:author` |
| 公開日 | `date:YYYY-MM-DD` |
| カテゴリ | `category:Programming` など |
| 明示された言語 | `language:ja` など |

欠落項目は省略します。空の説明で既存 Summary を消さず、言語は UI の言語や本文から推測しません。
タグ値のカンマ・改行は空白に置換します。既存タグの保持・重複処理は LANraragi 本体に任せます。

## 取得処理と制限

- PDF は公開されたリンクから取得します。投稿 ID から PDF の URL を推測しません。
- CBZ はプレビュー画像ではなく、プレイヤーが明示する閲覧用画像を使用します。画像の再圧縮は行いません。
- HTTP 通信は逐次実行し、画像間は250ms空けます。各リクエストのタイムアウトは60秒です。
- 接続失敗・429・5xx は最大2回再試行します。待機は1秒・2秒を基本とし、数値の `Retry-After` は最大30秒まで反映します。
- HTML / oEmbed 応答は16 MiB、PDF / CBZ の画像合計は512 MiB、CBZ は2,000ページを上限とします。
- リダイレクトは最大5回で、投稿ページは `speakerdeck.com` / `www.speakerdeck.com`、配信ファイルは `files.speakerdeck.com` に限定します。
- PDF の署名、画像の形式、画像 URL の所属投稿を確認します。画像が1枚でも取得できなければ CBZ を登録しません。

HTML の JSON-LD を主に利用し、Open Graph と投稿本文の DOM を補完に使います。
タイトル・投稿者表示名が欠ける場合のみ oEmbed を補助利用します。
Speaker Deck の HTML 構造や配信ホストが変更された場合は、解析処理の更新が必要です。

## 開発・テスト

LANraragi の Perl 環境では既存の依存を利用できます。独立した開発環境では次を実行してください。

```sh
cpanm --installdeps .
prove -Ilib -r t
```

通常のテストは fixture と HTTP モックを使い、外部通信を行いません。
PDF の元バイト列、CBZ のページ順・内容、途中失敗時の後片付け、HTTP 再試行・リダイレクト、
Unicode の解析、単発引数と `source:` の優先関係を確認します。
GitHub Actions でも Perl 5.36 で同じテストを実行します。

公開サイトでの確認は別のテストです。PDF 付き投稿と PDF リンクのない投稿を実際に取得します。
ファイルは一時ディレクトリに保存して、終了時に削除します。

```sh
SPEAKERDECK_LIVE_TESTS=1 prove -Ilib xt/live.t
```

最終的な導入確認では LANraragi 上で PDF / CBZ の登録・ページ表示、`source:` 付与、自動 Metadata 実行、
タイトル変更設定への追従を確認してください。単体テストと公開サイトの疎通テストは、この本体上の確認を代替しません。

## 参考資料

- [LANraragi プラグイン仕様](https://sugoi.gitbook.io/lanraragi/plugin-docs/index)
- [Downloader](https://sugoi.gitbook.io/lanraragi/plugin-docs/download) / [Metadata](https://sugoi.gitbook.io/lanraragi/plugin-docs/metadata)
- [Speaker Deck FAQ（oEmbed・ダウンロード設定）](https://speakerdeck.com/faq)

MIT License.
