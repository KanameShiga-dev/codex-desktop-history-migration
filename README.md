# Codex Desktop History Migration for Windows

Windows版 Codex Desktop のローカルタスク履歴を、旧PCから新PCへ移すためのPowerShellツールです。

次のデータを移行します。

- タスク／スレッドのメタデータ
- `sessions` 内の会話JSONL
- アーカイブ済みセッション
- 添付ファイル
- セッションインデックス
- ピン留め、プロジェクト表示順、ワークスペース登録
- スレッドに紐づくGoal

認証情報、端末ID、実行ログ、キャッシュ、プラグイン、スキルは移行しません。`auth.json` もコピーしません。

> [!WARNING]
> このツールはCodex Desktopのローカル保存形式を扱うコミュニティーツールであり、OpenAI公式の移行ツールではありません。Codexの更新によってDBスキーマや保存場所が変わる可能性があります。必ずエクスポート、検証、バックアップを行い、移行完了まで旧PCを消去しないでください。

## 必要環境

- Windows 11
- Windows PowerShell 5.1またはPowerShell 7
- Python 3
- 旧PCと新PCのCodex Desktopを、できるだけ同じバージョンに更新済み
- 新PCでCodex Desktopへ一度サインインし、初期データを生成済み

`migrate_codex_history.ps1` と `codex_history_db.py` は、必ず同じフォルダーへ置いてください。

## 基本的な移行

### 1. 旧PCからエクスポート

PowerShellを開き、ツールを置いたフォルダーへ移動します。

```powershell
cd C:\Tools\codex-desktop-history-migration
Set-ExecutionPolicy -Scope Process Bypass

.\migrate_codex_history.ps1 `
  -Mode Export `
  -PackagePath 'D:\Codex-History-Transfer'
```

`-Scope Process` の設定は、そのPowerShell画面を閉じると解除されます。

出力先が存在する場合は停止します。内容を確認したうえで作り直す場合だけ `-Force` を指定してください。

### 2. 移行パッケージを検証

```powershell
.\migrate_codex_history.ps1 `
  -Mode Verify `
  -PackagePath 'D:\Codex-History-Transfer'
```

`Verification passed` と表示されることを確認します。各ファイルのサイズとSHA-256が検査されます。

検証後、移行パッケージとこのツールの2ファイルを新PCへコピーしてください。

### 3. 新PCへインポート

1. 新PCでCodex Desktopを一度起動し、サインインします。
2. Codex Desktopを完全に終了します。
3. PowerShellでインポートします。

```powershell
cd C:\Tools\codex-desktop-history-migration
Set-ExecutionPolicy -Scope Process Bypass

.\migrate_codex_history.ps1 `
  -Mode Import `
  -PackagePath 'D:\Codex-History-Transfer'
```

インポート前の新環境DBとUI設定は、次の形式で自動退避されます。

```text
%USERPROFILE%\.codex\migration-backup-YYYYMMDD-HHMMSS
```

完了後にCodex Desktopを起動し直し、タスク一覧、本文、添付ファイル、アーカイブ済みタスクを確認します。

## 新旧でプロジェクトフォルダーが異なる場合

新PCでプロジェクトの配置場所を変更した場合は、`-PathMap` が必須です。

例：

```text
旧PC: C:\Dev\ProjectA
新PC: D:\Workspace\ProjectA

旧PC: C:\Training
新PC: D:\Workspace\Training
```

実行例：

```powershell
.\migrate_codex_history.ps1 `
  -Mode Import `
  -PackagePath 'D:\Codex-History-Transfer' `
  -PathMap 'C:\Dev\ProjectA=D:\Workspace\ProjectA','C:\Training=D:\Workspace\Training'
```

`-PathMap` は `旧ルート=新ルート` の形式で、複数指定できます。ルート配下のサブフォルダーも同じ対応で変換されます。

パス変換では次の3箇所を合わせて更新します。

- SQLiteのスレッド `cwd`
- Codex Desktopのプロジェクト／ワークスペース登録
- JSONL内部にJSONエスケープ形式で記録された旧 `cwd`

最後のJSONL変換が欠けると、タスクを開いた瞬間に旧プロジェクトへ戻り、一覧から消えたように見えることがあります。正常な変換時は次のメッセージが表示されます。

```text
Codex Desktop project paths repaired
Session log paths repaired: N files
```

## Codexホームが標準以外の場合

通常は `%USERPROFILE%\.codex` を使用します。別の保存先を使う場合は明示します。

```powershell
.\migrate_codex_history.ps1 `
  -Mode Export `
  -CodexHome 'D:\Profiles\codex-home' `
  -PackagePath 'E:\Codex-History-Transfer'
```

インポート時も、新環境で実際に参照されているCodexホームを指定してください。

### WSLを使用している場合

このPowerShellツールはWindows側のCodexホームを対象にします。Codex CLIやIDE拡張がWSL内で動いている場合、実際の保存先は `/home/<user>/.codex` の可能性があります。その場合、Windows側へインポートしても参照されません。使用中のCodexプロセスがWindows側かWSL側かを確認してから移行してください。

## 安全上の注意

- インポート中はCodex Desktopを起動しないでください。
- 移行パッケージには会話本文と添付ファイルが含まれます。USBメモリや共有ストレージ上で安全に管理してください。
- `auth.json`、APIキー、トークン、パスワードを移行パッケージへ追加しないでください。
- `-Force` は出力パッケージの再作成や既存ファイルの上書きを伴います。内容を確認してから使用してください。
- `manifest.json` のサイズ／ハッシュ不一致が出た場合は、検証を迂回せず旧PCで再エクスポートしてください。
- 新PCで作成済みのタスクと同じIDがある場合、既存レコードを維持しつつパス情報を更新します。
- 移行が安定するまで、旧PC、移行パッケージ、自動作成されたバックアップを削除しないでください。

## ドライラン

インポート処理の対象だけを確認する場合：

```powershell
.\migrate_codex_history.ps1 `
  -Mode Import `
  -PackagePath 'D:\Codex-History-Transfer' `
  -WhatIf
```

## トラブルシューティング

### スクリプトの実行が無効

PowerShellを開き直すたびに、次を実行します。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

### タスクが一度表示された後に消える

次を確認してください。

1. 新旧でプロジェクトパスが変わっていないか
2. 変わっている場合、すべての旧ルートを `-PathMap` へ指定したか
3. `Codex Desktop project paths repaired` が表示されたか
4. `Session log paths repaired: N files` が表示されたか
5. 新しいプロジェクトフォルダーが実際に存在するか
6. Windows側とWSL側のどちらの `.codex` が使用されているか

### `Size mismatch` または `Hash mismatch`

移行パッケージが作成後に変更されています。インポートを続行せず、旧PCから新しいパッケージを作成してください。

### `0 rows imported`

同じIDのレコードが既に存在する場合に表示されます。パス変換やインデックス修復は別途実行されるため、続く出力も確認してください。

## 移行対象外

次のデータは移行しません。

- `auth.json`
- インストールID、端末固有ID
- ログ、キャッシュ、一時ファイル
- プラグイン、スキル
- ブラウザー状態
- Codex本体やPythonなどの実行環境

これらは新PCで再インストール、再認証、再設定してください。

## ファイル

- `migrate_codex_history.ps1`: エクスポート、検証、インポート、パス変換
- `codex_history_db.py`: SQLiteメタデータのポータブルな書き出し／取り込み
