using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;

namespace LanjingQuiz;

/// <summary>原生 CookieCloud 配置对话框:打开时 GET 预填当前配置,
/// 保存时 POST(密码留空不修改),成功后自动触发一次同步。</summary>
internal sealed class CookieCloudForm : Form
{
    private readonly string _baseUrl;
    private readonly HttpClient _http;
    private readonly CheckBox _enabledCheck = new() { Text = "启用同步" };
    private readonly TextBox _serverBox = new() { PlaceholderText = "https://cc.example.com" };
    private readonly TextBox _uuidBox = new() { PlaceholderText = "扩展设置中的 UUID" };
    private readonly TextBox _passwordBox = new() { UseSystemPasswordChar = true, PlaceholderText = "留空不修改" };
    private readonly Label _statusLabel = new() { ForeColor = SystemColors.GrayText, AutoSize = true };
    private readonly Label _errorLabel = new() { ForeColor = Color.Firebrick, AutoSize = true };
    private readonly Button _saveButton = new() { Text = "保存", DialogResult = DialogResult.None };

    public CookieCloudForm(string baseUrl, HttpClient http)
    {
        _baseUrl = baseUrl;
        _http = http;

        Text = "Cookie 服务器";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(440, 320);

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
            ColumnCount = 1,
            RowCount = 10,
            AutoSize = true,
        };
        for (int i = 0; i < 10; i++)
        {
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, i == 9 ? 40 : 30));
        }

        layout.Controls.Add(_enabledCheck, 0, 0);
        layout.Controls.Add(MakeLabel("服务器地址"), 0, 1);
        layout.Controls.Add(_serverBox, 0, 2);
        layout.Controls.Add(MakeLabel("UUID"), 0, 3);
        layout.Controls.Add(_uuidBox, 0, 4);
        layout.Controls.Add(MakeLabel("密码"), 0, 5);
        layout.Controls.Add(_passwordBox, 0, 6);
        layout.Controls.Add(_statusLabel, 0, 7);
        layout.Controls.Add(_errorLabel, 0, 8);

        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill };
        var cancelButton = new Button { Text = "取消", DialogResult = DialogResult.Cancel };
        _saveButton.Click += async (_, _) => await SaveAsync();
        buttons.Controls.Add(_saveButton);
        buttons.Controls.Add(cancelButton);
        layout.Controls.Add(buttons, 0, 9);

        Controls.Add(layout);
        AcceptButton = _saveButton;
        CancelButton = cancelButton;

        _ = LoadAsync(); // fire-and-forget; errors land in _errorLabel
    }

    private Label MakeLabel(string text) => new() { Text = text, AutoSize = true, Font = new Font(Font.FontFamily, 9f, FontStyle.Bold) };

    private async Task LoadAsync()
    {
        try
        {
            using var response = await _http.GetAsync($"{_baseUrl}/api/cookiecloud");
            var json = JsonNode.Parse(await response.Content.ReadAsStringAsync());
            _enabledCheck.Checked = json?["enabled"]?.GetValue<bool>() ?? false;
            _serverBox.Text = json?["server"]?.GetValue<string>() ?? "";
            _uuidBox.Text = json?["uuid"]?.GetValue<string>() ?? "";
            _passwordBox.PlaceholderText = (json?["hasPassword"]?.GetValue<bool>() ?? false)
                ? "已保存,留空不修改"
                : "未设置";
            _passwordBox.Text = "";
            _statusLabel.Text = BuildStatus(
                json?["lastPush"]?.GetValue<string>() ?? "",
                json?["lastPull"]?.GetValue<string>() ?? "",
                json?["lastError"]?.GetValue<string>() ?? "");
        }
        catch (Exception ex)
        {
            _errorLabel.Text = $"读取配置失败:{ex.Message}";
        }
    }

    private async Task SaveAsync()
    {
        _saveButton.Enabled = false;
        _errorLabel.Text = "";
        try
        {
            var payload = new JsonObject
            {
                ["enabled"] = _enabledCheck.Checked,
                ["server"] = _serverBox.Text?.Trim() ?? "",
                ["uuid"] = _uuidBox.Text?.Trim() ?? "",
            };
            if (!string.IsNullOrEmpty(_passwordBox.Text))
            {
                payload["password"] = _passwordBox.Text;
            }

            using var content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");
            using var response = await _http.PostAsync($"{_baseUrl}/api/cookiecloud", content);
            var json = JsonNode.Parse(await response.Content.ReadAsStringAsync());
            if (response.IsSuccessStatusCode && json?["server"] != null)
            {
                // 配置即生效:触发一次同步(server 单飞,失败静默进 lastError)。
                _ = _http.PostAsync($"{_baseUrl}/api/cookiecloud/sync", null).ContinueWith(_ => { });
                DialogResult = DialogResult.OK;
                Close();
            }
            else
            {
                _errorLabel.Text = json?["error"]?.GetValue<string>() ?? "保存失败";
            }
        }
        catch (Exception ex)
        {
            _errorLabel.Text = $"保存失败:{ex.Message}";
        }
        finally
        {
            _saveButton.Enabled = true;
        }
    }

    private static string BuildStatus(string lastPush, string lastPull, string lastError)
    {
        if (!string.IsNullOrEmpty(lastError)) return $"上次同步失败:{lastError}";
        var parts = new List<string>();
        if (!string.IsNullOrEmpty(lastPull)) parts.Add($"上次拉取 {FormatTime(lastPull)}");
        if (!string.IsNullOrEmpty(lastPush)) parts.Add($"上次推送 {FormatTime(lastPush)}");
        return parts.Count > 0 ? string.Join(" · ", parts) : "尚未同步";
    }

    private static string FormatTime(string iso)
    {
        if (DateTimeOffset.TryParse(iso, out var dto)) return dto.ToLocalTime().ToString("HH:mm");
        return iso;
    }
}
