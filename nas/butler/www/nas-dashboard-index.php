<?php
header("Content-Type: text/html; charset=utf-8");

$tv_mode = (isset($_GET["view"]) && $_GET["view"] === "tv");

// ─── InfluxDB query via PHP curl (allow_url_fopen=off on this firmware) ───
function influx_query(string $q, string $db = "health_metrics"): ?array {
    $url = "http://127.0.0.1:8086/query?db=" . urlencode($db) . "&q=" . urlencode($q);
    $ch  = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL            => $url,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 3,
        CURLOPT_CONNECTTIMEOUT => 2,
        CURLOPT_FAILONERROR    => false,
    ]);
    $r = curl_exec($ch);
    curl_close($ch);
    return ($r !== false && $r !== "") ? json_decode($r, true) : null;
}

// Pull a single latest value from a measurement+field
function influx_latest(string $measurement, string $field, string $db = "health_metrics") {
    $r = influx_query(
        "SELECT last($field) AS v FROM $measurement",
        $db
    );
    return $r["results"][0]["series"][0]["values"][0][1] ?? null;
}

// Pull all fields for a measurement, latest row, keyed by column name
function influx_latest_row(string $measurement, string $db = "health_metrics"): array {
    $r = influx_query("SELECT * FROM $measurement ORDER BY time DESC LIMIT 1", $db);
    $series = $r["results"][0]["series"][0] ?? null;
    if (!$series) return [];
    $cols = $series["columns"];
    $vals = $series["values"][0];
    return array_combine($cols, $vals);
}

function influx_latest_body_composition(string $db = "health_metrics"): array {
  $q = "SELECT * FROM body_composition WHERE source='mi_scale_2' ORDER BY time DESC LIMIT 1";
  $r = influx_query($q, $db);
  $series = $r["results"][0]["series"][0] ?? null;
  if (!$series) return [];
  $cols = $series["columns"];
  $vals = $series["values"][0];
  return array_combine($cols, $vals);
}

function fs_stats(string $path): ?array {
  if (!is_dir($path)) return null;
  $total = @disk_total_space($path);
  $free = @disk_free_space($path);
  if (!is_numeric($total) || !is_numeric($free) || $total <= 0) return null;
  $used = $total - $free;
  return [
    "path" => $path,
    "total_gb" => round($total / 1073741824, 1),
    "free_gb" => round($free / 1073741824, 1),
    "used_gb" => round($used / 1073741824, 1),
    "used_pct" => round(($used / $total) * 100, 1),
  ];
}

function age_minutes(?string $iso8601): ?int {
  if (!$iso8601) return null;
  try {
    $event = new DateTime($iso8601);
    $now = new DateTime("now", new DateTimeZone("UTC"));
    $diff = $now->getTimestamp() - $event->getTimestamp();
    return (int)floor($diff / 60);
  } catch (Exception $e) {
    return null;
  }
}

// Pull latest row per tag value (e.g. per drive label)
function influx_latest_per_tag(string $measurement, string $tag, string $db = "health_metrics"): array {
    $r = influx_query("SELECT * FROM $measurement GROUP BY $tag ORDER BY time DESC LIMIT 1", $db);
    $out = [];
    foreach (($r["results"][0]["series"] ?? []) as $s) {
        $key  = $s["tags"][$tag] ?? "?";
        $cols = $s["columns"];
        $vals = $s["values"][0];
        $out[$key] = array_combine($cols, $vals);
    }
    return $out;
}

// ─── /proc based stats ────────────────────────────────────────────────────
$mem       = @file_get_contents("/proc/meminfo");
preg_match("/MemAvailable:\s+(\d+)/", (string)$mem, $m);
$mem_avail = isset($m[1]) ? (int)round($m[1] / 1024) : null;
preg_match("/MemTotal:\s+(\d+)/", (string)$mem, $mt);
$mem_total = isset($mt[1]) ? (int)round($mt[1] / 1024) : null;

$loadavg   = @file_get_contents("/proc/loadavg");
$load_1    = $loadavg ? explode(" ", $loadavg)[0] : "?";

$uptime_s  = (int)explode(" ", (string)@file_get_contents("/proc/uptime"))[0];
$uptime_h  = (int)floor($uptime_s / 3600);
$uptime_m  = (int)floor(($uptime_s % 3600) / 60);

// ─── InfluxDB health_metrics ───────────────────────────────────────────────
$sys_row    = influx_latest_row("nas_system");
$drive_rows = influx_latest_per_tag("nas_drive", "drive");
$mi_scale_row = influx_latest_body_composition();

$cpu_temp   = isset($sys_row["cpu_temp_c"]) ? (float)$sys_row["cpu_temp_c"] : null;

// ─── Storage + IoT runtime status ────────────────────────────────────────
$raid_stats = fs_stats("/mnt/HD/HD_a2");
$usb_stats  = fs_stats("/mnt/USB/USB1_c1");
$share_stats = [];
foreach ((glob("/shares/*") ?: []) as $share_path) {
  if (is_dir($share_path)) {
    $s = fs_stats($share_path);
    if ($s) $share_stats[] = $s;
  }
}

$modules_txt = (string)@file_get_contents("/proc/modules");
$bt_core_loaded = (strpos($modules_txt, "bluetooth ") !== false);
$bt_usb_loaded = (strpos($modules_txt, "btusb ") !== false);
$bt_ifaces = glob("/sys/class/bluetooth/hci*") ?: [];
$bt_operational = ($bt_core_loaded && !empty($bt_ifaces));

$mi_scale_runner = "/mnt/HD/HD_a2/wayne/run-mi-scale-collector.sh";
$mi_scale_runner_present = is_file($mi_scale_runner);
$mi_scale_proc_running = trim((string)shell_exec("pgrep -f 'mi-scale|run-mi-scale-collector' 2>/dev/null")) !== "";
$mi_scale_last_age_min = age_minutes($mi_scale_row["time"] ?? null);
$mi_scale_data_fresh = ($mi_scale_last_age_min !== null && $mi_scale_last_age_min <= 1440);

// ─── InfluxDB database list ───────────────────────────────────────────────
$dbs_raw = influx_query("SHOW DATABASES", "_internal");
$dbs_raw = $dbs_raw ?? influx_query("SHOW DATABASES", "health_metrics");
$db_list = [];
if ($dbs_raw && isset($dbs_raw["results"][0]["series"][0]["values"])) {
    foreach ($dbs_raw["results"][0]["series"][0]["values"] as $v) {
        if ($v[0] !== "_internal") $db_list[] = $v[0];
    }
}
$influx_ok = ($dbs_raw !== null);

// ─── Helper: thermal CSS class ────────────────────────────────────────────
function temp_class(?float $t): string {
    if ($t === null) return "";
    if ($t >= 90)   return "err";
    if ($t >= 80)   return "warn";
    return "ok";
}
function temp_bar(?float $t, float $max = 100): string {
    if ($t === null) return "";
    $pct = min(100, max(0, ($t / $max) * 100));
    $cls = temp_class($t);
    return "<div class='bar-wrap'><div class='bar $cls' style='width:{$pct}%'></div></div>";
}
?><!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NAS Edge Node</title>
<meta http-equiv="refresh" content="30">
<style>
*{box-sizing:border-box;margin:0;padding:0;}
body{font-family:monospace;background:#0d1117;color:#c9d1d9;padding:1.5em;}
h1{color:#58a6ff;font-size:1.2em;margin-bottom:1em;}
h2{color:#3fb950;font-size:0.95em;margin-bottom:0.6em;text-transform:uppercase;letter-spacing:.05em;}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:1em;max-width:1100px;}
.box{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:1em;}
table{border-collapse:collapse;width:100%;}
td,th{padding:5px 10px;text-align:left;border-bottom:1px solid #21262d;font-size:0.9em;}
td:first-child{color:#8b949e;white-space:nowrap;width:50%;}
th{color:#8b949e;font-size:0.8em;}
tr:last-child td{border-bottom:none;}
.ok  {color:#3fb950;}
.warn{color:#d29922;}
.err {color:#f85149;}
.badge{display:inline-block;padding:2px 8px;border-radius:4px;font-size:0.8em;font-weight:bold;}
.badge.ok  {background:#1a3a1a;color:#3fb950;}
.badge.warn{background:#3a2e0a;color:#d29922;}
.badge.err {background:#3a1010;color:#f85149;}
.bar-wrap{background:#21262d;border-radius:3px;height:6px;width:100%;margin-top:4px;}
.bar{height:6px;border-radius:3px;transition:width .3s;}
.bar.ok  {background:#3fb950;}
.bar.warn{background:#d29922;}
.bar.err {background:#f85149;}
.temp-val{font-weight:bold;}
.sub{color:#484f58;font-size:0.8em;margin-top:1.2em;text-align:right;}
.influx-ok{color:#3fb950;font-size:0.85em;margin-bottom:0.5em;}
.influx-err{color:#f85149;font-size:0.85em;margin-bottom:0.5em;}
.section-label{color:#8b949e;font-size:0.75em;text-transform:uppercase;letter-spacing:.05em;margin:0.8em 0 0.3em;}
a{color:#58a6ff;text-decoration:none;}
a:hover{text-decoration:underline;}

<?php if ($tv_mode): ?>
body{font-size:20px;padding:1em;}
h1{font-size:1.7em;}
h2{font-size:1.15em;}
td,th{font-size:1em;padding:8px 12px;}
.grid{grid-template-columns:repeat(auto-fit,minmax(420px,1fr));max-width:1800px;}
.badge{font-size:0.95em;padding:5px 10px;}
<?php endif; ?>
</style></head>
<body>
<h1>&#9670; WD MyCloud EX2 Ultra — IoT Edge Node<?= $tv_mode ? " (TV View)" : "" ?></h1>
<div class="grid">

  <!-- ── System ───────────────────────────────────── -->
  <div class="box">
    <h2>System</h2>
    <table>
      <tr><td>Host</td><td><?= htmlspecialchars((string)gethostname()) ?></td></tr>
      <tr><td>Uptime</td><td><?= $uptime_h ?>h <?= $uptime_m ?>m</td></tr>
      <tr><td>Load (1m)</td><td><?= $load_1 ?></td></tr>
      <tr><td>Free RAM</td>
          <td><?= $mem_avail !== null ? "$mem_avail MB / $mem_total MB" : "?" ?></td></tr>
      <tr><td>Time</td><td><?= date("Y-m-d H:i:s T") ?></td></tr>
    </table>
  </div>

  <!-- ── Storage ─────────────────────────────────── -->
  <div class="box">
    <h2>Storage</h2>
    <table>
      <?php if ($raid_stats): ?>
      <tr><td>RAID volume</td><td><?= $raid_stats["used_gb"] ?> / <?= $raid_stats["total_gb"] ?> GB (<?= $raid_stats["used_pct"] ?>%)</td></tr>
      <tr><td>RAID free</td><td><?= $raid_stats["free_gb"] ?> GB</td></tr>
      <?php else: ?>
      <tr><td>RAID volume</td><td class="warn">unavailable</td></tr>
      <?php endif; ?>

      <?php if ($usb_stats): ?>
      <tr><td>USB drive</td><td><?= $usb_stats["used_gb"] ?> / <?= $usb_stats["total_gb"] ?> GB (<?= $usb_stats["used_pct"] ?>%)</td></tr>
      <tr><td>USB free</td><td><?= $usb_stats["free_gb"] ?> GB</td></tr>
      <?php else: ?>
      <tr><td>USB drive</td><td class="warn">not mounted</td></tr>
      <?php endif; ?>
    </table>

    <?php if (!empty($share_stats)): ?>
    <p class="section-label">NAS shares</p>
    <table>
      <?php foreach ($share_stats as $s): ?>
      <tr>
        <td><?= htmlspecialchars(basename($s["path"])) ?></td>
        <td><?= $s["used_pct"] ?>% used (<?= $s["free_gb"] ?> GB free)</td>
      </tr>
      <?php endforeach; ?>
    </table>
    <?php endif; ?>
  </div>

  <!-- ── Thermal ──────────────────────────────────── -->
  <div class="box">
    <h2>Thermal</h2>
    <table>
      <?php
      // CPU temperature from health_metrics nas_system
      if ($cpu_temp !== null):
        $cc = temp_class($cpu_temp);
        $warn_note = $cpu_temp >= 90 ? " — THROTTLE RISK" : ($cpu_temp >= 80 ? " — elevated" : "");
      ?>
      <tr>
        <td>CPU (Marvell A385 SoC)</td>
        <td>
          <span class="temp-val <?= $cc ?>"><?= $cpu_temp ?>°C</span>
          <span class="<?= $cc ?>"><?= $warn_note ?></span>
          <?= temp_bar($cpu_temp, 100) ?>
        </td>
      </tr>
      <?php else: ?>
      <tr><td>CPU</td><td class="warn">no data</td></tr>
      <?php endif; ?>

      <?php foreach ($drive_rows as $drv => $row):
        $dt  = isset($row["temp_c"]) ? (float)$row["temp_c"] : null;
        $dc  = temp_class($dt);
        $poh = isset($row["power_on_hours"]) ? number_format((int)$row["power_on_hours"]) : "?";
        $lc  = isset($row["load_cycles"])    ? number_format((int)$row["load_cycles"])    : "?";
      ?>
      <tr>
        <td>/dev/<?= htmlspecialchars($drv) ?></td>
        <td>
          <?php if ($dt !== null): ?>
            <span class="temp-val <?= $dc ?>"><?= $dt ?>°C</span>
            <?= temp_bar($dt, 65) ?>
          <?php else: ?>
            <span class="warn">no data</span>
          <?php endif; ?>
        </td>
      </tr>
      <?php endforeach; ?>

      <?php if (empty($drive_rows)): ?>
      <tr><td colspan="2" class="warn">Drive data pending — health collector starting up</td></tr>
      <?php endif; ?>
    </table>

    <?php if (!empty($drive_rows)):
      $first = array_values($drive_rows)[0];
      $poh = isset($first["power_on_hours"]) ? number_format((int)$first["power_on_hours"]) : "?";
      $lc  = isset($first["load_cycles"])    ? number_format((int)$first["load_cycles"])    : "?";
    ?>
    <p class="section-label">Drive stats (sda)</p>
    <table>
      <tr><td>Power-on hours</td><td><?= $poh ?></td></tr>
      <tr><td>Load cycles</td>
          <td><span class="<?= (int)str_replace(",","",$lc) > 600000 ? "warn" : "ok" ?>"><?= $lc ?></span></td></tr>
    </table>
    <?php endif; ?>
  </div>

  <!-- ── InfluxDB ─────────────────────────────────── -->
  <div class="box">
    <h2>InfluxDB 1.8</h2>
    <?php if ($influx_ok): ?>
      <p class="influx-ok">&#9679; Running on :8086</p>
      <table>
        <tr><th>Database</th></tr>
        <?php foreach ($db_list as $db): ?>
        <tr><td><?= htmlspecialchars($db) ?></td></tr>
        <?php endforeach; ?>
      </table>
    <?php else: ?>
      <p class="influx-err">&#10007; InfluxDB unreachable</p>
    <?php endif; ?>

    <?php if ($cpu_temp !== null && isset($sys_row["time"])): ?>
    <p class="section-label">Last metrics sample</p>
    <table>
      <tr><td>Collected</td><td style="font-size:0.8em"><?= htmlspecialchars($sys_row["time"]) ?></td></tr>
      <?php if (isset($sys_row["load_1m"])): ?>
      <tr><td>Load 1m (NAS)</td><td><?= $sys_row["load_1m"] ?></td></tr>
      <?php endif; ?>
      <?php if (isset($sys_row["mem_available_mb"])): ?>
      <tr><td>Free RAM (metric)</td><td><?= $sys_row["mem_available_mb"] ?> MB</td></tr>
      <?php endif; ?>
    </table>
    <?php endif; ?>
  </div>

  <!-- ── Services ─────────────────────────────────── -->
  <div class="box">
    <h2>Services</h2>
    <table>
      <?php
      $svcs = [
          "influxd"        => ["label" => "InfluxDB",                        "want" => true],
          "otaclientd"     => ["label" => "WD OTA (should be stopped)",      "want" => false],
          "wdtms"          => ["label" => "WD Telemetry (should be stopped)", "want" => false],
          "restsdk-server" => ["label" => "restsdk (cloud proxy)",            "want" => false],
          "tailscaled"     => ["label" => "Tailscale VPN",                   "want" => true],
          "nas_health_col" => ["label" => "Health collector",                "want" => true],
            "mosquitto"      => ["label" => "MQTT broker (Mosquitto)",         "want" => true],
            "telegraf"       => ["label" => "Telegraf health agent",            "want" => true],
            "wg-quick"       => ["label" => "WireGuard",                        "want" => false],
            "dockerd"        => ["label" => "Docker runtime",                   "want" => false],
      ];
      foreach ($svcs as $bin => $info):
          $running = trim((string)shell_exec("pgrep -f " . escapeshellarg($bin) . " 2>/dev/null")) !== "";
          $ok      = $info["want"] ? $running : !$running;
          $cls     = $ok ? "ok" : "warn";
          $status  = $running ? "RUNNING" : "STOPPED";
      ?>
      <tr>
        <td><?= htmlspecialchars($info["label"]) ?></td>
        <td><span class="badge <?= $cls ?>"><?= $status ?></span></td>
      </tr>
      <?php endforeach; ?>
    </table>

    <p class="section-label">Bluetooth + Mi Scale link</p>
    <table>
      <tr>
        <td>Bluetooth modules</td>
        <td>
          <span class="badge <?= $bt_core_loaded ? "ok" : "warn" ?>">core <?= $bt_core_loaded ? "LOADED" : "MISSING" ?></span>
          <span class="badge <?= $bt_usb_loaded ? "ok" : "warn" ?>">btusb <?= $bt_usb_loaded ? "LOADED" : "MISSING" ?></span>
        </td>
      </tr>
      <tr>
        <td>Bluetooth operational</td>
        <td><span class="badge <?= $bt_operational ? "ok" : "warn" ?>"><?= $bt_operational ? "YES" : "NO" ?></span></td>
      </tr>
      <tr>
        <td>Mi Scale runner script</td>
        <td><span class="badge <?= $mi_scale_runner_present ? "ok" : "warn" ?>"><?= $mi_scale_runner_present ? "PRESENT" : "MISSING" ?></span></td>
      </tr>
      <tr>
        <td>Mi Scale collector process</td>
        <td><span class="badge <?= $mi_scale_proc_running ? "ok" : "warn" ?>"><?= $mi_scale_proc_running ? "RUNNING" : "STOPPED" ?></span></td>
      </tr>
      <tr>
        <td>Last Mi Scale sample</td>
        <td>
          <?php if ($mi_scale_last_age_min !== null): ?>
            <span class="badge <?= $mi_scale_data_fresh ? "ok" : "warn" ?>"><?= $mi_scale_last_age_min ?> min ago</span>
          <?php else: ?>
            <span class="badge warn">NO DATA</span>
          <?php endif; ?>
        </td>
      </tr>
    </table>
  </div>

</div>
<p class="sub">Auto-refreshes every 30s &mdash; PHP <?= PHP_VERSION ?> &mdash;
   Tailnet: <a href="http://100.106.225.96:8080/">100.106.225.96:8080</a> &mdash;
   TV: <a href="?view=tv">/index.php?view=tv</a></p>
</body></html>
