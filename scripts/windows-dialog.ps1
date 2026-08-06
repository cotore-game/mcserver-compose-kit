param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('SelectWorld', 'InputMotd', 'Check')]
    [string]$Mode,

    [string]$DefaultValue = ''
)

$ErrorActionPreference = 'Stop'

function Write-Utf8Base64 {
    param([string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    [Console]::Out.Write([Convert]::ToBase64String($bytes))
}

if ($Mode -eq 'Check') {
    Write-Utf8Base64 'ok'
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if ($Mode -eq 'SelectWorld') {
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "配布ワールドを選択します。`r`n`r`nZIPファイルを選ぶ場合は「はい」`r`n展開済みフォルダを選ぶ場合は「いいえ」",
        'Minecraft Server Kit',
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
        exit 1
    }

    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = '配布ワールドのZIPを選択'
        $dialog.Filter = 'ZIPファイル (*.zip)|*.zip|すべてのファイル (*.*)|*.*'
        $dialog.CheckFileExists = $true
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            exit 1
        }
        Write-Utf8Base64 $dialog.FileName
        exit 0
    }

    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = '配布ワールド、またはその外側の配布フォルダを選択'
    $folderDialog.ShowNewFolderButton = $false
    if ($folderDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        exit 1
    }
    Write-Utf8Base64 $folderDialog.SelectedPath
    exit 0
}

if ($Mode -eq 'InputMotd') {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Minecraft Server Kit'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(520, 150)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'マルチプレイ一覧に表示する説明（MOTD）を入力してください。'
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(16, 18)
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Text = $DefaultValue
    $textBox.Location = New-Object System.Drawing.Point(18, 50)
    $textBox.Size = New-Object System.Drawing.Size(484, 28)
    $form.Controls.Add($textBox)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Location = New-Object System.Drawing.Point(346, 100)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'キャンセル'
    $cancelButton.Location = New-Object System.Drawing.Point(427, 100)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton
    $form.Add_Shown({ $textBox.SelectAll(); $textBox.Focus() })

    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        exit 1
    }
    Write-Utf8Base64 $textBox.Text
}
