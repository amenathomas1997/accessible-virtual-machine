// AVMKeyboard.cs
// AVM — Accessible Virtual Machine
//
// AVM Keyboard (2026-10-29, the user's request): where a Mac keyboard's
// Option and Command keys land in Windows, chosen in Windows itself, in a
// small window NVDA, JAWS and Narrator read. AVM sends them as printed
// (Option is Alt, Command is the Windows key); this app remaps them the way
// SharpKeys does, with the registry's Scancode Map, which applies to every
// keyboard in Windows after a restart. A remap done on the Mac side
// instead (AVM 0.4.8 to 0.4.11) never gave the user Alt-Tab; SharpKeys's
// did. Only the four keys below are touched: any other remap stays.
//
// AVM installs it (AVM/WindowsApps.swift) in C:\ProgramData\AVM\bin with
// a Start menu shortcut. It asks for administrator rights, as any change
// to the Scancode Map does.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using Microsoft.Win32;

static class AVMKeyboard
{
    // The scancodes AVM sends for a Mac's Option and Command keys.
    const ushort LeftAlt = 0x0038, LeftWindows = 0xE05B, RightAlt = 0xE038, RightWindows = 0xE05C;
    const ushort Insert = 0xE052, Applications = 0xE05D;
    static readonly ushort[] OurKeys = { LeftAlt, LeftWindows, RightAlt, RightWindows };
    const string KeyPath = @"SYSTEM\CurrentControlSet\Control\Keyboard Layout";

    sealed class Layout
    {
        public string Title, Keys;
        public Dictionary<ushort, ushort> Map;   // the key pressed -> what Windows gets
    }

    static readonly Layout[] Layouts =
    {
        new Layout {
            Title = "As printed: Option is Alt, Command is the Windows key",
            Keys = "Nothing is remapped. Option is Alt and Command is the Windows key, as printed on a Mac keyboard.",
            Map = new Dictionary<ushort, ushort>() },
        new Layout {
            Title = "PC order, Mac keyboard without a number pad",
            Keys = "Option is the Windows key and Command is Alt, as on a PC. Right Option is Insert, for your screen reader, and right Command is the Applications key, for context menus.",
            Map = new Dictionary<ushort, ushort> { { LeftAlt, LeftWindows }, { LeftWindows, LeftAlt }, { RightAlt, Insert }, { RightWindows, Applications } } },
        new Layout {
            Title = "PC order, Mac keyboard with a number pad",
            Keys = "Option is the Windows key and Command is Alt, as on a PC. Right Command is Right Alt and right Option is the Applications key; number-pad 0 is Insert with Num Lock off.",
            Map = new Dictionary<ushort, ushort> { { LeftAlt, LeftWindows }, { LeftWindows, LeftAlt }, { RightWindows, RightAlt }, { RightAlt, Applications } } },
    };

    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new KeyboardForm());
    }

    // MARK: The Scancode Map

    /// The entries there now: key pressed -> what Windows gets.
    static Dictionary<ushort, ushort> ReadMap()
    {
        var map = new Dictionary<ushort, ushort>();
        using (var key = Registry.LocalMachine.OpenSubKey(KeyPath))
        {
            var bytes = key == null ? null : key.GetValue("Scancode Map") as byte[];
            if (bytes == null || bytes.Length < 16) return map;
            int count = BitConverter.ToInt32(bytes, 8);
            for (int i = 0; i < count - 1 && 12 + i * 4 + 3 < bytes.Length; i++)
            {
                ushort to = BitConverter.ToUInt16(bytes, 12 + i * 4);
                ushort from = BitConverter.ToUInt16(bytes, 14 + i * 4);
                if (from != 0) map[from] = to;
            }
        }
        return map;
    }

    static void WriteMap(Dictionary<ushort, ushort> map)
    {
        using (var key = Registry.LocalMachine.CreateSubKey(KeyPath))
        {
            if (map.Count == 0) { key.DeleteValue("Scancode Map", false); return; }
            var bytes = new List<byte>(new byte[8]);
            bytes.AddRange(BitConverter.GetBytes(map.Count + 1));
            foreach (var entry in map)
            {
                bytes.AddRange(BitConverter.GetBytes(entry.Value));
                bytes.AddRange(BitConverter.GetBytes(entry.Key));
            }
            bytes.AddRange(new byte[4]);
            key.SetValue("Scancode Map", bytes.ToArray(), RegistryValueKind.Binary);
        }
    }

    /// The layout the map has now for our four keys, or -1 for another remap.
    static int CurrentLayout(Dictionary<ushort, ushort> map)
    {
        for (int i = 0; i < Layouts.Length; i++)
        {
            bool same = true;
            foreach (ushort k in OurKeys)
            {
                ushort want, have;
                bool wanted = Layouts[i].Map.TryGetValue(k, out want), had = map.TryGetValue(k, out have);
                if (wanted != had || (wanted && want != have)) { same = false; break; }
            }
            if (same) return i;
        }
        return -1;
    }

    /// The map with our four keys set to the layout's, the rest kept.
    static Dictionary<ushort, ushort> WithLayout(Dictionary<ushort, ushort> map, Layout layout)
    {
        var result = new Dictionary<ushort, ushort>(map);
        foreach (ushort k in OurKeys) result.Remove(k);
        foreach (var entry in layout.Map) result[entry.Key] = entry.Value;
        return result;
    }

    // MARK: The window

    sealed class KeyboardForm : Form
    {
        readonly RadioButton[] choices = new RadioButton[Layouts.Length];
        readonly Label keys = new Label();
        readonly Label status = new Label();
        int saved;

        public KeyboardForm()
        {
            Text = "AVM Keyboard";
            Font = new Font("Segoe UI", 10f);
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Padding = new Padding(16);

            var panel = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Dock = DockStyle.Fill };
            var intro = new Label { AutoSize = true, MaximumSize = new Size(520, 0),
                Text = "Choose where your Mac keyboard's Option and Command keys go in Windows. Windows uses the change after it restarts." };
            panel.Controls.Add(intro);

            var group = new GroupBox { Text = "Option and Command", AutoSize = true, Padding = new Padding(10) };
            var inGroup = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Dock = DockStyle.Fill };
            for (int i = 0; i < Layouts.Length; i++)
            {
                int index = i;
                choices[i] = new RadioButton { Text = Layouts[i].Title, AutoSize = true, TabIndex = i };
                choices[i].CheckedChanged += (s, e) => { if (choices[index].Checked) keys.Text = Layouts[index].Keys; };
                inGroup.Controls.Add(choices[i]);
            }
            group.Controls.Add(inGroup);
            panel.Controls.Add(group);

            keys.AutoSize = true;
            keys.MaximumSize = new Size(520, 0);
            panel.Controls.Add(keys);
            status.AutoSize = true;
            status.MaximumSize = new Size(520, 0);
            panel.Controls.Add(status);

            var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true };
            var apply = new Button { Text = "&Apply", AutoSize = true };
            apply.Click += (s, e) => Apply();
            var restart = new Button { Text = "&Restart Windows now", AutoSize = true };
            restart.Click += (s, e) => Restart();
            var close = new Button { Text = "Close", AutoSize = true };
            close.Click += (s, e) => Close();
            buttons.Controls.Add(apply);
            buttons.Controls.Add(restart);
            buttons.Controls.Add(close);
            panel.Controls.Add(buttons);
            Controls.Add(panel);
            AcceptButton = apply;
            CancelButton = close;

            var map = ReadMap();
            saved = CurrentLayout(map);
            if (saved >= 0)
            {
                choices[saved].Checked = true;
                status.Text = "Now: " + Layouts[saved].Title + ".";
            }
            else
            {
                status.Text = "Now: another remap of these keys, from SharpKeys or another tool. Choosing one here replaces it for Option and Command only.";
                keys.Text = "Choose a layout.";
            }
        }

        int Chosen()
        {
            for (int i = 0; i < choices.Length; i++) if (choices[i].Checked) return i;
            return -1;
        }

        void Apply()
        {
            int chosen = Chosen();
            if (chosen < 0) { MessageBox.Show(this, "Choose a layout first.", "AVM Keyboard"); return; }
            try
            {
                WriteMap(WithLayout(ReadMap(), Layouts[chosen]));
            }
            catch (Exception e)
            {
                MessageBox.Show(this, "Windows didn't save it: " + e.Message, "AVM Keyboard", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            saved = chosen;
            status.Text = "Saved: " + Layouts[chosen].Title + ". It takes effect when Windows restarts.";
            if (MessageBox.Show(this, "Saved. Windows uses the new keys after it restarts. Restart Windows now?", "AVM Keyboard",
                                MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes) Restart();
        }

        void Restart()
        {
            Process.Start(new ProcessStartInfo("shutdown.exe", "/r /t 5 /c \"AVM Keyboard: restarting for the new keys.\"") { UseShellExecute = false, CreateNoWindow = true });
            Close();
        }
    }
}
