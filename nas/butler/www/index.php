<?php
header("Content-Type: text/html; charset=utf-8");

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

$cpu_temp   = isset($sys_row["cpu_temp_c"]) ? (float)$sys_row["cpu_temp_c"] : null;

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

// ─── Electricity usage data ────────────────────────────────────────────────
$elec_raw = influx_query(
    "SELECT time, delta_energy FROM smartthings_electricity_interval ORDER BY time ASC LIMIT 96",
    "electricity_usage"
);
$elec_series  = $elec_raw["results"][0]["series"][0] ?? null;
$elec_cols    = $elec_series["columns"] ?? [];
$elec_vals    = $elec_series["values"]  ?? [];
$elec_points  = [];  // [["time"=>..., "delta_energy"=>...], ...]
if ($elec_series) {
    $ti = array_search("time",         $elec_cols);
    $ei = array_search("delta_energy", $elec_cols);
    foreach ($elec_vals as $row) {
        $elec_points[] = [
            "time"         => $row[$ti],
            "delta_energy" => (float)($row[$ei] ?? 0),
        ];
    }
}

// Summary stats for electricity
$elec_total_wh = array_sum(array_column($elec_points, "delta_energy"));
$elec_total_kwh = round($elec_total_wh / 1000, 3);
$elec_peak_wh   = $elec_points ? max(array_column($elec_points, "delta_energy")) : null;
$elec_count     = count($elec_points);
$elec_latest_ts = $elec_points ? end($elec_points)["time"] : null;

// Build JS-safe arrays
$elec_js_labels = json_encode(array_map(function($p) {
    // Convert ISO UTC timestamp to HH:MM label
    $ts = strtotime($p["time"]);
    return $ts ? gmdate("D H:i", $ts) : $p["time"];
}, $elec_points));
$elec_js_values = json_encode(array_column($elec_points, "delta_energy"));

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
.box.full-width{grid-column:1/-1;}
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
/* Electricity chart */
.elec-stats{display:flex;gap:2em;margin-bottom:0.8em;flex-wrap:wrap;}
.elec-stat{display:flex;flex-direction:column;}
.elec-stat .val{font-size:1.4em;font-weight:bold;color:#58a6ff;}
.elec-stat .lbl{font-size:0.7em;color:#8b949e;text-transform:uppercase;letter-spacing:.05em;}
.chart-wrap{position:relative;width:100%;height:200px;}
.elec-no-data{color:#8b949e;font-size:0.9em;padding:2em 0;}
</style></head>
<body>
<h1>&#9670; WD MyCloud EX2 Ultra — IoT Edge Node</h1>
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
  </div>

  <!-- ── Electricity ──────────────────────────────── -->
  <div class="box full-width">
    <h2>&#9889; Electricity — Smart Meter (30-min intervals)</h2>
    <?php if ($elec_count > 0): ?>
    <div class="elec-stats">
      <div class="elec-stat">
        <span class="val"><?= number_format($elec_total_kwh, 3) ?> kWh</span>
        <span class="lbl">Total (<?= $elec_count ?> intervals)</span>
      </div>
      <div class="elec-stat">
        <span class="val"><?= number_format($elec_peak_wh ?? 0) ?> Wh</span>
        <span class="lbl">Peak half-hour</span>
      </div>
      <div class="elec-stat">
        <span class="val"><?= number_format($elec_total_wh / max(1,$elec_count)) ?> Wh</span>
        <span class="lbl">Avg per interval</span>
      </div>
      <?php if ($elec_latest_ts): ?>
      <div class="elec-stat">
        <span class="val" style="font-size:1em"><?= htmlspecialchars(gmdate("Y-m-d H:i", strtotime($elec_latest_ts))) ?> UTC</span>
        <span class="lbl">Latest interval end</span>
      </div>
      <?php endif; ?>
    </div>
    <div class="chart-wrap">
      <canvas id="elecChart"></canvas>
    </div>
    <script>
    (function(){
      var labels = <?= $elec_js_labels ?>;
      var values = <?= $elec_js_values ?>;
      // Compute bar colours: top 10% are amber, rest are blue
      var max = Math.max.apply(null, values);
      var threshold = max * 0.9;
      var colors = values.map(function(v){
        return v >= threshold ? 'rgba(210,153,34,0.85)' : 'rgba(88,166,255,0.75)';
      });
      var borderColors = values.map(function(v){
        return v >= threshold ? 'rgba(210,153,34,1)' : 'rgba(88,166,255,1)';
      });
      var ctx = document.getElementById('elecChart').getContext('2d');
      new Chart(ctx, {
        type: 'bar',
        data: {
          labels: labels,
          datasets: [{
            label: 'Energy (Wh)',
            data: values,
            backgroundColor: colors,
            borderColor: borderColors,
            borderWidth: 1,
            borderRadius: 2,
          }]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          animation: false,
          plugins: {
            legend: { display: false },
            tooltip: {
              backgroundColor: '#1c2128',
              borderColor: '#30363d',
              borderWidth: 1,
              titleColor: '#8b949e',
              bodyColor: '#c9d1d9',
              callbacks: {
                label: function(ctx) {
                  return ctx.parsed.y.toFixed(0) + ' Wh';
                }
              }
            }
          },
          scales: {
            x: {
              grid: { color: '#21262d' },
              ticks: {
                color: '#8b949e',
                font: { size: 10, family: 'monospace' },
                maxRotation: 45,
                autoSkip: true,
                maxTicksLimit: 12,
              }
            },
            y: {
              grid: { color: '#21262d' },
              ticks: {
                color: '#8b949e',
                font: { size: 10, family: 'monospace' },
                callback: function(v){ return v + ' Wh'; }
              },
              beginAtZero: true,
            }
          }
        }
      });
    })();
    </script>
    <?php else: ?>
    <p class="elec-no-data">No interval data yet — collector runs at :10 and :40 past each hour.</p>
    <?php endif; ?>
  </div>

</div>
<p class="sub">Auto-refreshes every 30s &mdash; PHP <?= PHP_VERSION ?> &mdash;
   Tailnet: <a href="http://100.106.225.96:8080/" style="color:#58a6ff">100.106.225.96:8080</a></p>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.4/dist/chart.umd.min.js"></script>
</body></html>
