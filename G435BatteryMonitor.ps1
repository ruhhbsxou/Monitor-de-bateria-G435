Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$nativeCode = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class G435BatteryReading
{
    public int Percent { get; set; }
    public int Millivolts { get; set; }
}

public sealed class G435BatteryResult
{
    public G435BatteryReading Reading { get; set; }
    public string Error { get; set; }
}

public sealed class G435BatteryJob
{
    private readonly object gate = new object();
    private bool busy;
    private bool hasResult;
    private G435BatteryResult result;

    public bool IsBusy { get { lock (gate) return busy; } }
    public bool HasResult { get { lock (gate) return hasResult; } }

    public void Start()
    {
        lock (gate)
        {
            if (busy)
                return;
            busy = true;
            hasResult = false;
            result = null;
        }

        Thread thread = new Thread(delegate()
        {
            G435BatteryResult completed = new G435BatteryResult();
            try
            {
                completed.Reading = G435BatteryReader.ReadBattery();
            }
            catch (Exception ex)
            {
                completed.Error = ex.Message;
            }
            finally
            {
                lock (gate)
                {
                    result = completed;
                    hasResult = true;
                    busy = false;
                }
            }
        });
        thread.IsBackground = true;
        thread.Name = "G435BatteryReader";
        thread.Start();
    }

    public G435BatteryResult TakeResult()
    {
        lock (gate)
        {
            if (!hasResult)
                return null;
            G435BatteryResult completed = result;
            result = null;
            hasResult = false;
            return completed;
        }
    }
}

public static class G435BatteryReader
{
    private const ushort VendorId = 0x046D;
    private const ushort ProductIdAcb = 0x0ACB;
    private const ushort ProductIdAdf = 0x0ADF;
    private const ushort UsagePageAcb = 0xFFC0;
    private const ushort UsagePageAdf = 0xFF00;
    private const byte ReportId = 6;

    private sealed class DeviceInfo
    {
        public string Path;
        public ushort ProductId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DeviceInterfaceData
    {
        public int Size;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HidAttributes
    {
        public int Size;
        public ushort VendorId;
        public ushort ProductId;
        public ushort VersionNumber;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HidCapabilities
    {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
        public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps;
        public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices;
        public ushort NumberOutputButtonCaps;
        public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps;
        public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    [DllImport("hid.dll")]
    private static extern void HidD_GetHidGuid(out Guid hidGuid);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetAttributes(IntPtr device, ref HidAttributes attributes);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetPreparsedData(IntPtr device, out IntPtr data);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_FreePreparsedData(IntPtr data);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern int HidP_GetCaps(IntPtr data, out HidCapabilities capabilities);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_SetFeature(IntPtr device, byte[] report, int length);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetFeature(IntPtr device, byte[] report, int length);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, IntPtr enumerator, IntPtr parent, uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(IntPtr deviceInfoSet, IntPtr deviceInfoData, ref Guid interfaceClassGuid, uint memberIndex, ref DeviceInterfaceData interfaceData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr deviceInfoSet, ref DeviceInterfaceData interfaceData, IntPtr detailData, uint detailDataSize, out uint requiredSize, IntPtr deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string fileName, uint access, uint shareMode, IntPtr security, uint creationDisposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadFile(IntPtr file, IntPtr buffer, uint bytesToRead, out uint bytesRead, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(IntPtr file, byte[] buffer, uint bytesToWrite, out uint bytesWritten, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetOverlappedResult(IntPtr file, IntPtr overlapped, out uint bytesTransferred, bool wait);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CancelIoEx(IntPtr file, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateEvent(IntPtr attributes, bool manualReset, bool initialState, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static IntPtr OpenDevice(string path, uint flags)
    {
        return CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, flags, IntPtr.Zero);
    }

    private static DeviceInfo FindDevice()
    {
        Guid hidGuid;
        HidD_GetHidGuid(out hidGuid);
        IntPtr set = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero, 0x12);
        if (set == IntPtr.Zero || set == new IntPtr(-1))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Nao foi possivel enumerar os dispositivos HID.");

        try
        {
            DeviceInfo alternate = null;
            for (uint index = 0; ; index++)
            {
                DeviceInterfaceData item = new DeviceInterfaceData();
                item.Size = Marshal.SizeOf(typeof(DeviceInterfaceData));
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref hidGuid, index, ref item))
                    break;

                uint required;
                SetupDiGetDeviceInterfaceDetail(set, ref item, IntPtr.Zero, 0, out required, IntPtr.Zero);
                if (required == 0)
                    continue;

                IntPtr detail = Marshal.AllocHGlobal((int)required);
                try
                {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref item, detail, required, out required, IntPtr.Zero))
                        continue;

                    string path = Marshal.PtrToStringUni(IntPtr.Add(detail, 4));
                    IntPtr device = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                    if (device == IntPtr.Zero || device == new IntPtr(-1))
                        continue;

                    try
                    {
                        HidAttributes attributes = new HidAttributes();
                        attributes.Size = Marshal.SizeOf(typeof(HidAttributes));
                        if (!HidD_GetAttributes(device, ref attributes))
                            continue;
                        if (attributes.VendorId != VendorId ||
                            (attributes.ProductId != ProductIdAcb && attributes.ProductId != ProductIdAdf))
                            continue;

                        IntPtr preparsed;
                        if (!HidD_GetPreparsedData(device, out preparsed))
                            continue;
                        try
                        {
                            HidCapabilities capabilities;
                            int status = HidP_GetCaps(preparsed, out capabilities);
                            ushort page = attributes.ProductId == ProductIdAcb ? UsagePageAcb : UsagePageAdf;
                            if (status == 0x00110000 && capabilities.UsagePage == page)
                            {
                                DeviceInfo found = new DeviceInfo { Path = path, ProductId = attributes.ProductId };
                                if (attributes.ProductId == ProductIdAcb)
                                    return found;
                                if (alternate == null)
                                    alternate = found;
                            }
                        }
                        finally
                        {
                            HidD_FreePreparsedData(preparsed);
                        }
                    }
                    finally
                    {
                        CloseHandle(device);
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(detail);
                }
            }
            if (alternate != null)
                return alternate;
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(set);
        }

        throw new InvalidOperationException("Receptor LIGHTSPEED G435 nao encontrado (USB 046D:0ACB/0ADF).");
    }

    private sealed class HidSession : IDisposable
    {
        private readonly IntPtr control;
        private byte sequence = 1;

        public HidSession(DeviceInfo device)
        {
            control = OpenDevice(device.Path, 0x40000000);
            if (control == IntPtr.Zero || control == new IntPtr(-1))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Nao foi possivel abrir o receptor HID.");
        }

        public void Dispose()
        {
            if (control != IntPtr.Zero && control != new IntPtr(-1))
                CloseHandle(control);
        }

        private byte[] ReadInput(uint timeout)
        {
            IntPtr buffer = Marshal.AllocHGlobal(65);
            IntPtr signal = CreateEvent(IntPtr.Zero, true, false, null);
            if (signal == IntPtr.Zero)
            {
                Marshal.FreeHGlobal(buffer);
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Nao foi possivel aguardar a resposta HID.");
            }

            int overlappedSize = IntPtr.Size == 8 ? 32 : 20;
            IntPtr pending = Marshal.AllocHGlobal(overlappedSize);
            for (int i = 0; i < overlappedSize; i++)
                Marshal.WriteByte(pending, i, 0);
            Marshal.WriteIntPtr(pending, IntPtr.Size * 2 + 8, signal);

            try
            {
                uint received;
                if (!ReadFile(control, buffer, 65, out received, pending))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error != 997)
                        throw new Win32Exception(error, "Falha ao ler a resposta do receptor.");

                    uint state = WaitForSingleObject(signal, timeout);
                    if (state == 0xFFFFFFFF)
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Falha ao aguardar a resposta HID.");
                    if (state != 0)
                    {
                        CancelIoEx(control, pending);
                        WaitForSingleObject(signal, 0xFFFFFFFF);
                        return null;
                    }
                    if (!GetOverlappedResult(control, pending, out received, false))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Falha ao concluir a leitura HID.");
                }

                if (received == 0)
                    return null;
                byte[] raw = new byte[received];
                Marshal.Copy(buffer, raw, 0, (int)received);
                int offset = received >= 65 ? 1 : 0;
                int count = Math.Min(64, (int)received - offset);
                byte[] result = new byte[count];
                Buffer.BlockCopy(raw, offset, result, 0, count);
                return result;
            }
            finally
            {
                CloseHandle(signal);
                Marshal.FreeHGlobal(pending);
                Marshal.FreeHGlobal(buffer);
            }
        }

        private void Bridge(byte operation, byte subOperation, byte[] body)
        {
            byte[] report = new byte[64];
            report[0] = ReportId;
            report[1] = operation;
            report[2] = subOperation;
            if (body != null)
                Buffer.BlockCopy(body, 0, report, 3, Math.Min(body.Length, report.Length - 3));
            if (!HidD_SetFeature(control, report, report.Length))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "O receptor recusou um comando HID.");

            DateTime deadline = DateTime.UtcNow.AddMilliseconds(800);
            while (DateTime.UtcNow < deadline)
            {
                byte[] response = ReadInput(100);
                if (response != null && response.Length >= 2 && response[0] == ReportId)
                {
                    if (response[1] == 0x5A || response[1] == 0xFE)
                        return;
                    throw new IOException("O receptor retornou uma confirmacao HID inesperada.");
                }
            }
            throw new TimeoutException("O receptor nao confirmou o comando HID.");
        }

        private byte[] GetFeature()
        {
            byte[] report = new byte[64];
            report[0] = ReportId;
            if (!HidD_GetFeature(control, report, report.Length) || report[1] == 0xFF)
                return null;
            return report;
        }

        private byte[] Query(byte category, byte length, byte[] payload, Func<byte[], bool> matches)
        {
            byte[] command = new byte[5 + payload.Length];
            command[0] = 0x50;
            command[1] = 0x41;
            command[2] = category;
            command[3] = sequence;
            command[4] = length;
            Buffer.BlockCopy(payload, 0, command, 5, payload.Length);
            sequence = (byte)(sequence % 127 + 1);
            byte[] message = new byte[command.Length + 1];
            message[0] = (byte)command.Length;
            Buffer.BlockCopy(command, 0, message, 1, command.Length);
            Bridge(0x04, 0x03, message);

            DateTime deadline = DateTime.UtcNow.AddMilliseconds(1500);
            while (DateTime.UtcNow < deadline)
            {
                byte[] report = GetFeature();
                if (report != null && matches(report))
                    return report;
                Thread.Sleep(30);
            }
            return null;
        }

        private static byte? FindRemoteValue(byte[] report, byte command)
        {
            for (int i = 0; i + 3 < report.Length; i++)
                if (report[i] == 0x02 && report[i + 1] == 0x00 && report[i + 2] == command)
                    return report[i + 3];
            return null;
        }

        public static int? FindBatteryMillivolts(byte[] report)
        {
            for (int i = 0; i + 6 < report.Length; i++)
            {
                if (report[i] == 0x07 && report[i + 1] == 0x00 &&
                    report[i + 2] == 0x06 && (report[i + 3] & 0x80) != 0 &&
                    report[i + 4] == 0x00)
                {
                    int mv = report[i + 5] | (report[i + 6] << 8);
                    if (mv >= 2500 && mv <= 4600)
                        return mv;
                }
            }
            return null;
        }

        public G435BatteryReading ReadBattery()
        {
            Exception failure = null;
            try
            {
                Bridge(0x01, 0x03, null);
                for (int i = 0; i < 16; i++)
                {
                    if (GetFeature() == null)
                        break;
                }

                byte[] connectedReply = Query(0x0E, 1, new byte[] { 0xE3 },
                    delegate(byte[] report) { return FindRemoteValue(report, 0xE3).HasValue; });
                byte? connected = connectedReply == null ? null : FindRemoteValue(connectedReply, 0xE3);
                if (connected == 0)
                    throw new InvalidOperationException("Headset desconectado. Ligue o G435 e confirme o modo LIGHTSPEED.");

                byte[] modeReply = Query(0x0E, 1, new byte[] { 0xE0 },
                    delegate(byte[] report) { return FindRemoteValue(report, 0xE0).HasValue; });
                byte? mode = modeReply == null ? null : FindRemoteValue(modeReply, 0xE0);
                if (mode != 1)
                    Query(0x0E, 2, new byte[] { 0xE1, 0x01 }, delegate(byte[] report) { return true; });

                byte[] batteryReply = Query(0x06, 1, new byte[] { 0x00, 0x31 },
                    delegate(byte[] report) { return FindBatteryMillivolts(report).HasValue; });
                int? millivolts = batteryReply == null ? null : FindBatteryMillivolts(batteryReply);
                if (millivolts == null)
                    throw new TimeoutException("Sem resposta do headset. LED ciano confirma o modo, nao o pareamento LIGHTSPEED.");

                return new G435BatteryReading {
                    Millivolts = millivolts.Value,
                    Percent = ToPercent(millivolts.Value)
                };
            }
            catch (Exception ex)
            {
                failure = ex;
                throw;
            }
            finally
            {
                try
                {
                    Bridge(0x08, 0x03, null);
                }
                catch (Exception cleanupError)
                {
                    if (failure == null)
                        throw;
                    throw new AggregateException("A leitura falhou e nao foi possivel restaurar o receptor.", failure, cleanupError);
                }
            }
        }

        private static byte[] Frame(byte command, byte[] body)
        {
            byte[] frame = new byte[64];
            frame[0] = command;
            frame[1] = (byte)body.Length;
            Buffer.BlockCopy(body, 0, frame, 4, body.Length);
            ushort crc = Crc16Xmodem(frame);
            frame[2] = (byte)(crc & 0xFF);
            frame[3] = (byte)(crc >> 8);
            return frame;
        }

        public static ushort Crc16Xmodem(byte[] data)
        {
            ushort crc = 0;
            for (int i = 0; i < data.Length; i++)
            {
                crc ^= (ushort)(data[i] << 8);
                for (int bit = 0; bit < 8; bit++)
                    crc = (ushort)((crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1);
            }
            return crc;
        }

        private List<byte[]> Transact(byte[] frame, int waitMilliseconds)
        {
            byte[] output = new byte[65];
            Buffer.BlockCopy(frame, 0, output, 1, frame.Length);
            uint written;
            if (!WriteFile(control, output, (uint)output.Length, out written, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Falha ao enviar um comando ao receptor.");

            List<byte[]> replies = new List<byte[]>();
            DateTime deadline = DateTime.UtcNow.AddMilliseconds(waitMilliseconds);
            while (DateTime.UtcNow < deadline)
            {
                int remaining = (int)Math.Max(1, (deadline - DateTime.UtcNow).TotalMilliseconds);
                byte[] reply = ReadInput((uint)Math.Min(remaining, 100));
                if (reply != null)
                    replies.Add(reply);
            }
            return replies;
        }

        private byte[] BuildPa(byte category, byte length, byte[] payload)
        {
            byte[] command = new byte[5 + payload.Length];
            command[0] = 0x50;
            command[1] = 0x41;
            command[2] = category;
            command[3] = sequence;
            command[4] = length;
            Buffer.BlockCopy(payload, 0, command, 5, payload.Length);
            sequence = (byte)(sequence % 127 + 1);
            return Frame(0x80, command);
        }

        public G435BatteryReading ReadAdfBattery()
        {
            byte[] sessionInit = {
                0x50, 0x41, 0x06, 0x01, 0x0D, 0x00, 0x25, 0x34, 0x12, 0x5A,
                0x5A, 0x01, 0x00, 0x00, 0x00, 0xF0, 0x00, 0x00, 0x00
            };
            Exception failure = null;
            try
            {
                Transact(Frame(0x84, new byte[] { 0x01 }), 50);
                Transact(Frame(0x85, new byte[] { 0x01 }), 50);
                Transact(Frame(0x80, sessionInit), 450);
                sequence = 2;
                Transact(BuildPa(0x0E, 1, new byte[] { 0xE0 }), 120);
                Transact(BuildPa(0x0E, 2, new byte[] { 0xE1, 0x01 }), 120);
                Transact(BuildPa(0x0E, 1, new byte[] { 0xE0 }), 120);
                List<byte[]> replies = Transact(BuildPa(0x06, 1, new byte[] { 0x00, 0x31 }), 250);
                int? millivolts = null;
                for (int i = 0; i < replies.Count && millivolts == null; i++)
                    millivolts = FindBatteryMillivolts(replies[i]);
                if (millivolts == null)
                    throw new TimeoutException("O headset nao retornou a bateria. Ligue-o e tente novamente.");
                return new G435BatteryReading {
                    Millivolts = millivolts.Value,
                    Percent = ToPercent(millivolts.Value)
                };
            }
            catch (Exception ex)
            {
                failure = ex;
                throw;
            }
            finally
            {
                try
                {
                    Transact(Frame(0x85, new byte[] { 0x02 }), 50);
                }
                catch (Exception cleanupError)
                {
                    if (failure == null)
                        throw;
                    throw new AggregateException("A leitura falhou e nao foi possivel encerrar a sessao HID.", failure, cleanupError);
                }
            }
        }
    }

    public static G435BatteryReading ReadBattery()
    {
        DeviceInfo device = FindDevice();
        using (HidSession session = new HidSession(device))
            return device.ProductId == ProductIdAdf ? session.ReadAdfBattery() : session.ReadBattery();
    }

    public static int ToPercent(int millivolts)
    {
        int[] volts = { 4200, 4150, 4100, 4050, 4000, 3950, 3900, 3850, 3800, 3750, 3700, 3650, 3600, 3550, 3500, 3400 };
        int[] levels = { 100, 95, 90, 85, 80, 75, 70, 62, 55, 45, 35, 25, 15, 10, 5, 0 };
        if (millivolts >= volts[0])
            return 100;
        for (int i = 0; i < volts.Length - 1; i++)
        {
            if (millivolts >= volts[i + 1])
            {
                double fraction = (double)(millivolts - volts[i + 1]) / (volts[i] - volts[i + 1]);
                return (int)Math.Round(levels[i + 1] + fraction * (levels[i] - levels[i + 1]), MidpointRounding.AwayFromZero);
            }
        }
        return 0;
    }
}
'@

Add-Type -TypeDefinition $nativeCode -Language CSharp -ErrorAction Stop

if ($env:G435_SELF_TEST -eq '1') {
    $ErrorActionPreference = 'Stop'
    if ([G435BatteryReader]::ToPercent(4300) -ne 100 -or
        [G435BatteryReader]::ToPercent(4146) -ne 95 -or
        [G435BatteryReader]::ToPercent(4125) -ne 93 -or
        [G435BatteryReader]::ToPercent(3725) -ne 40 -or
        [G435BatteryReader]::ToPercent(3300) -ne 0) {
        throw 'Falha no teste da conversao de tensao para percentual.'
    }

    $sessionType = [G435BatteryReader].GetNestedType('HidSession', [System.Reflection.BindingFlags]::NonPublic)
    $staticBindingFlags = [System.Reflection.BindingFlags]::Public -bor
        [System.Reflection.BindingFlags]::NonPublic -bor
        [System.Reflection.BindingFlags]::Static
    $crcMethod = $sessionType.GetMethod('Crc16Xmodem', $staticBindingFlags)
    $crcArguments = New-Object object[] 1
    $crcArguments[0] = [System.Text.Encoding]::ASCII.GetBytes('123456789')
    if ($crcMethod.Invoke($null, $crcArguments) -ne 0x31C3) {
        throw 'Falha no teste do checksum HID.'
    }

    $batteryParser = $sessionType.GetMethod('FindBatteryMillivolts', $staticBindingFlags)
    [byte[]]$reply = 0x06, 0x50, 0x49, 0x01, 0xC8, 0x75, 0x48, 0x0D, 0x00, 0x07, 0x00, 0x06, 0x82, 0x00, 0x32, 0x10
    $parseArguments = New-Object object[] 1
    $parseArguments[0] = $reply
    if ($batteryParser.Invoke($null, $parseArguments) -ne 4146) {
        throw 'Falha no teste da resposta de bateria HID.'
    }

    Write-Output 'Compilacao, checksum HID, parser e curva de bateria testados.'
    return
}

$logoPath = Join-Path $PSScriptRoot 'material\g435-logo.png'
$iconPath = Join-Path $PSScriptRoot 'material\g435-logo.ico'
if (-not (Test-Path -LiteralPath $logoPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    throw 'Os arquivos da logo nao foram encontrados na pasta material.'
}

$script:windowDragOffset = $null
$logoImage = [System.Drawing.Image]::FromFile($logoPath)
$appIcon = New-Object System.Drawing.Icon($iconPath)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Bateria G435'
$form.ClientSize = New-Object System.Drawing.Size(440, 226)
$form.FormBorderStyle = 'None'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.StartPosition = 'Manual'
$form.ShowInTaskbar = $true
$form.Icon = $appIcon
$form.BackColor = [System.Drawing.Color]::FromArgb(31, 33, 31)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($workArea.Right - $form.Width - 16), ($workArea.Bottom - $form.Height - 16))

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(440, 30)
$header.BackColor = [System.Drawing.Color]::FromArgb(26, 28, 26)
$form.Controls.Add($header)

$headerTitle = New-Object System.Windows.Forms.Label
$headerTitle.Text = 'Bateria G435'
$headerTitle.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$headerTitle.ForeColor = [System.Drawing.Color]::FromArgb(225, 228, 225)
$headerTitle.Location = New-Object System.Drawing.Point(12, 5)
$headerTitle.Size = New-Object System.Drawing.Size(330, 20)
$header.Controls.Add($headerTitle)

$minimizeButton = New-Object System.Windows.Forms.Button
$minimizeButton.Text = '-'
$minimizeButton.Location = New-Object System.Drawing.Point(374, 0)
$minimizeButton.Size = New-Object System.Drawing.Size(32, 29)
$minimizeButton.FlatStyle = 'Flat'
$minimizeButton.FlatAppearance.BorderSize = 0
$minimizeButton.BackColor = $header.BackColor
$minimizeButton.ForeColor = [System.Drawing.Color]::FromArgb(220, 223, 220)
$minimizeButton.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$minimizeButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$header.Controls.Add($minimizeButton)
$minimizeButton.Add_Click({ $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized })

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = 'x'
$closeButton.Location = New-Object System.Drawing.Point(406, 0)
$closeButton.Size = New-Object System.Drawing.Size(34, 29)
$closeButton.FlatStyle = 'Flat'
$closeButton.FlatAppearance.BorderSize = 0
$closeButton.BackColor = $header.BackColor
$closeButton.ForeColor = [System.Drawing.Color]::FromArgb(220, 223, 220)
$closeButton.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$closeButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$header.Controls.Add($closeButton)
$closeButton.Add_Click({ $form.Close() })

$dragControls = @($header, $headerTitle)
foreach ($control in $dragControls) {
    $control.Add_MouseDown({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $screenPoint = $sender.PointToScreen($eventArgs.Location)
            $script:windowDragOffset = New-Object System.Drawing.Point(($screenPoint.X - $form.Left), ($screenPoint.Y - $form.Top))
        }
    })
    $control.Add_MouseMove({
        param($sender, $eventArgs)
        if ($script:windowDragOffset -and $eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $screenPoint = $sender.PointToScreen($eventArgs.Location)
            $form.Location = New-Object System.Drawing.Point(($screenPoint.X - $script:windowDragOffset.X), ($screenPoint.Y - $script:windowDragOffset.Y))
        }
    })
    $control.Add_MouseUp({ $script:windowDragOffset = $null })
}

$iconTile = New-Object System.Windows.Forms.Panel
$iconTile.Location = New-Object System.Drawing.Point(20, 50)
$iconTile.Size = New-Object System.Drawing.Size(60, 60)
$iconTile.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($iconTile)
$logoView = New-Object System.Windows.Forms.PictureBox
$logoView.Dock = 'Fill'
$logoView.SizeMode = 'Zoom'
$logoView.Image = $logoImage
$iconTile.Controls.Add($logoView)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Bateria do Logitech G435'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$title.ForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$title.Location = New-Object System.Drawing.Point(96, 33)
$title.Size = New-Object System.Drawing.Size(300, 25)
$form.Controls.Add($title)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Pronto para consultar'
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 189, 185)
$statusLabel.Location = New-Object System.Drawing.Point(97, 63)
$statusLabel.Size = New-Object System.Drawing.Size(320, 22)
$statusLabel.AutoEllipsis = $true
$form.Controls.Add($statusLabel)

$percentLabel = New-Object System.Windows.Forms.Label
$percentLabel.Text = '--%'
$percentLabel.Font = New-Object System.Drawing.Font('Segoe UI Light', 29)
$percentLabel.ForeColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$percentLabel.Location = New-Object System.Drawing.Point(96, 83)
$percentLabel.Size = New-Object System.Drawing.Size(300, 48)
$form.Controls.Add($percentLabel)

$track = New-Object System.Windows.Forms.Panel
$track.Location = New-Object System.Drawing.Point(98, 133)
$track.Size = New-Object System.Drawing.Size(318, 5)
$track.BackColor = [System.Drawing.Color]::FromArgb(67, 70, 67)
$form.Controls.Add($track)
$bar = New-Object System.Windows.Forms.Panel
$bar.Location = New-Object System.Drawing.Point(0, 0)
$bar.Size = New-Object System.Drawing.Size(0, 5)
$bar.BackColor = [System.Drawing.Color]::FromArgb(91, 205, 143)
$track.Controls.Add($bar)

$updatedLabel = New-Object System.Windows.Forms.Label
$updatedLabel.Text = 'LIGHTSPEED  |  Aguardando atualizacao'
$updatedLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$updatedLabel.ForeColor = [System.Drawing.Color]::FromArgb(153, 158, 153)
$updatedLabel.Location = New-Object System.Drawing.Point(98, 148)
$updatedLabel.Size = New-Object System.Drawing.Size(232, 19)
$form.Controls.Add($updatedLabel)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Atualizar'
$refreshButton.Location = New-Object System.Drawing.Point(337, 146)
$refreshButton.Size = New-Object System.Drawing.Size(80, 25)
$refreshButton.FlatStyle = 'Flat'
$refreshButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90, 95, 90)
$refreshButton.BackColor = [System.Drawing.Color]::FromArgb(48, 51, 48)
$refreshButton.ForeColor = [System.Drawing.Color]::White
$refreshButton.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$refreshButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($refreshButton)

$noteLabel = New-Object System.Windows.Forms.Label
$noteLabel.Text = 'Atualizacao manual | A consulta pode interromper brevemente o audio.'
$noteLabel.Font = New-Object System.Drawing.Font('Segoe UI', 7.5)
$noteLabel.ForeColor = [System.Drawing.Color]::FromArgb(140, 145, 140)
$noteLabel.Location = New-Object System.Drawing.Point(20, 188)
$noteLabel.Size = New-Object System.Drawing.Size(410, 18)
$form.Controls.Add($noteLabel)

$toolTip = New-Object System.Windows.Forms.ToolTip
$job = New-Object G435BatteryJob
$resultTimer = New-Object System.Windows.Forms.Timer
$resultTimer.Interval = 250
$resultTimer.Add_Tick({
    if ($job.HasResult) {
        $resultTimer.Stop()
        $refreshButton.Enabled = $true
        $result = $job.TakeResult()
        if ($result.Error) {
            $percentLabel.Text = '--%'
            $bar.Width = 0
            $statusLabel.Text = 'Falha ao consultar o headset'
            $toolTip.SetToolTip($statusLabel, $result.Error)
            $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(235, 108, 108)
            $updatedLabel.Text = 'Verifique o receptor LIGHTSPEED'
        } else {
            $reading = $result.Reading
            $percentLabel.Text = "$($reading.Percent)%"
            $bar.Width = [Math]::Max(1, [int](318 * $reading.Percent / 100))
            $toolTip.SetToolTip($statusLabel, '')
            if ($reading.Percent -le 15) {
                $bar.BackColor = [System.Drawing.Color]::FromArgb(235, 82, 82)
                $statusLabel.Text = 'Bateria baixa'
                $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 116, 116)
            } else {
                $bar.BackColor = [System.Drawing.Color]::FromArgb(91, 205, 143)
                $statusLabel.Text = 'Nivel estimado da bateria'
                $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 189, 185)
            }
            $updatedLabel.Text = "LIGHTSPEED  |  Atualizado as $(Get-Date -Format 'HH:mm:ss')"
        }
    }
})

$refreshButton.Add_Click({
    if (-not $job.IsBusy) {
        $statusLabel.Text = 'Consultando o headset...'
        $toolTip.SetToolTip($statusLabel, '')
        $refreshButton.Enabled = $false
        $job.Start()
        $resultTimer.Start()
    }
})

$form.Add_FormClosed({
    $resultTimer.Stop()
    $resultTimer.Dispose()
    $logoImage.Dispose()
    $appIcon.Dispose()
})

if ($env:G435_UI_SELF_TEST -eq '1') {
    $form.Add_Shown({ $form.Close() })
    [void]$form.ShowDialog()
    Write-Output 'Windows Forms, logo e icone inicializados.'
    return
}

[void]$form.ShowDialog()
