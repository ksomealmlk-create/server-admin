import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'إدارة السيرفرات',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            colorSchemeSeed: Colors.blue),
        builder: (ctx, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const Home(),
      );
}

// ---------------------------------------------------------------- DigitalOcean
class DO {
  static String token = '';
  static const base = 'https://api.digitalocean.com/v2';
  static Map<String, String> get h => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json'
      };
  static Future<Map<String, dynamic>> req(String m, String p,
      [Map<String, dynamic>? body]) async {
    final u = Uri.parse(base + p);
    http.Response r;
    if (m == 'GET') {
      r = await http.get(u, headers: h);
    } else if (m == 'POST') {
      r = await http.post(u, headers: h, body: jsonEncode(body ?? {}));
    } else {
      r = await http.delete(u, headers: h);
    }
    final dynamic j = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body);
    if (r.statusCode >= 400) {
      throw Exception(j is Map
          ? (j['message'] ?? 'HTTP ${r.statusCode}')
          : 'HTTP ${r.statusCode}');
    }
    return Map<String, dynamic>.from(j as Map);
  }

  static String msg(Object e) => e.toString().replaceFirst('Exception: ', '');
}

// ---------------------------------------------------------------- helpers
Future<int?> tcpPing(String host, int port) async {
  final sw = Stopwatch()..start();
  try {
    final s =
        await Socket.connect(host, port, timeout: const Duration(seconds: 3));
    s.destroy();
    return sw.elapsedMilliseconds;
  } catch (_) {
    return null;
  }
}

Future<int?> avgPing(String host, int port) async {
  final t = <int>[];
  for (var i = 0; i < 3; i++) {
    final r = await tcpPing(host, port);
    if (r != null) t.add(r);
  }
  if (t.isEmpty) return null;
  return t.reduce((a, b) => a + b) ~/ t.length;
}

void snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

Future<bool> confirm(BuildContext c, String t) async =>
    await showDialog<bool>(
        context: c,
        builder: (x) => AlertDialog(title: Text(t), actions: [
              TextButton(
                  onPressed: () => Navigator.pop(x, false),
                  child: const Text('إلغاء')),
              TextButton(
                  onPressed: () => Navigator.pop(x, true),
                  child: const Text('تأكيد')),
            ])) ??
    false;

String ipOf(dynamic d) {
  for (final n in (d['networks']['v4'] as List)) {
    if (n['type'] == 'public') return n['ip_address'] as String;
  }
  return 'pending';
}

final _rnd = Random.secure();
String randHex(int bytes) => List.generate(
    bytes, (_) => _rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
String randPass(int n) {
  const cs = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return List.generate(n, (_) => cs[_rnd.nextInt(cs.length)]).join();
}

String uuid4() {
  final b = List<int>.generate(16, (_) => _rnd.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

// ---------------------------------------------------------------- local store
// Per-server info kept on the phone: root password, xray keys, clients, log.
class Store {
  static Map<String, Map<String, dynamic>> servers = {};
  static List<Map<String, dynamic>> panels = [];

  static void addPanel(String name, String url, String user, String pass) {
    if (panels.any((p) => p['url'] == url)) return;
    panels.add({'name': name, 'url': url, 'user': user, 'pass': pass});
  }

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('servers');
    servers = {};
    panels = [];
    final rp = p.getString('panels');
    if (rp != null) {
      panels = (jsonDecode(rp) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    if (raw != null) {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      m.forEach((k, v) => servers[k] = Map<String, dynamic>.from(v as Map));
    }
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('servers', jsonEncode(servers));
    await p.setString('panels', jsonEncode(panels));
  }
}

// ---------------------------------------------------------------- SSH
class Ssh {
  static Future<String> run(String host, String pass, String cmd,
      {String? input}) async {
    final socket =
        await SSHSocket.connect(host, 22, timeout: const Duration(seconds: 15));
    final c = SSHClient(socket, username: 'root', onPasswordRequest: () => pass);
    try {
      final s = await c.execute(cmd);
      if (input != null) s.stdin.add(Uint8List.fromList(utf8.encode(input)));
      await s.stdin.close();
      final res = await Future.wait([
        utf8.decodeStream(s.stdout.cast<List<int>>()),
        utf8.decodeStream(s.stderr.cast<List<int>>()),
      ]);
      await s.done;
      if ((s.exitCode ?? 0) != 0) {
        final e = (res[1].trim().isNotEmpty ? res[1] : res[0]).trim();
        throw Exception(e.length > 400 ? e.substring(e.length - 400) : e);
      }
      return res[0];
    } finally {
      c.close();
    }
  }
}

// ---------------------------------------------------------------- Xray
class Xray {
  static const cfgPath = '/usr/local/etc/xray/config.json';
  static const setup = r'''
set -e
export DEBIAN_FRONTEND=noninteractive
for i in 1 2 3 4 5 6; do
  if bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then break; fi
  sleep 15
done
test -x /usr/local/bin/xray
echo '===X25519==='
/usr/local/bin/xray x25519
echo '===VLESSENC==='
/usr/local/bin/xray vlessenc
''';

  static Map<String, String> parse(String out) {
    final parts = out.split('===X25519===');
    if (parts.length < 2) throw Exception('مخرجات التثبيت غير متوقعة');
    final xs = parts[1].split('===VLESSENC===');
    if (xs.length < 2) throw Exception('مخرجات التثبيت غير متوقعة');
    final vals = <String>[];
    for (final l in xs[0].split('\n')) {
      final m = RegExp(r':\s*(\S+)\s*$').firstMatch(l);
      if (m != null) vals.add(m.group(1)!);
    }
    if (vals.length < 2) throw Exception('تعذر قراءة مفاتيح x25519');
    final dec = RegExp(r'"decryption":\s*"([^"]+)"').firstMatch(xs[1]);
    final enc = RegExp(r'"encryption":\s*"([^"]+)"').firstMatch(xs[1]);
    if (dec == null || enc == null) throw Exception('تعذر قراءة مفاتيح vlessenc');
    return {
      'prv': vals[0],
      'pbk': vals[1],
      'dec': dec.group(1)!,
      'enc': enc.group(1)!
    };
  }

  static Map<String, dynamic> config(Map x, List clients) => {
        'log': {'loglevel': 'warning'},
        'inbounds': [
          {
            'listen': '0.0.0.0',
            'port': x['port'],
            'protocol': 'vless',
            'tag': 'in-443-tcp',
            'settings': {
              'clients': clients
                  .map((c) => {'id': c['id'], 'email': c['email']})
                  .toList(),
              'decryption': x['dec'],
            },
            'streamSettings': {
              'network': 'tcp',
              'security': 'reality',
              'realitySettings': {
                'show': false,
                'xver': 0,
                'target': x['target'],
                'serverNames': [x['sni']],
                'privateKey': x['prv'],
                'shortIds': x['sids'],
              },
            },
            'sniffing': {
              'enabled': true,
              'destOverride': ['http', 'tls', 'quic'],
            },
          }
        ],
        'outbounds': [
          {'protocol': 'freedom', 'tag': 'direct'},
          {'protocol': 'blackhole', 'tag': 'block'},
        ],
      };

  static Future<void> apply(Map s, List clients) async {
    final json =
        const JsonEncoder.withIndent('  ').convert(config(s['xray'], clients));
    await Ssh.run(
        s['ip'],
        s['pass'],
        'cat > $cfgPath.new && /usr/local/bin/xray run -test -config $cfgPath.new && mv $cfgPath.new $cfgPath && systemctl enable xray >/dev/null 2>&1 && systemctl restart xray && sleep 1 && systemctl is-active xray',
        input: json);
  }

  static String link(Map s, Map c) {
    final x = s['xray'] as Map;
    final q = Uri(queryParameters: {
      'type': 'tcp',
      'encryption': x['enc'],
      'security': 'reality',
      'support-x25519mlkem768': 'true',
      'pbk': x['pbk'],
      'fp': 'chrome',
      'sni': x['sni'],
      'sid': (x['sids'] as List).first,
      'spx': x['spx'],
    }).query;
    return 'vless://${c['id']}@${s['ip']}:${x['port']}?$q#${Uri.encodeComponent(c['email'])}';
  }
}

// ---------------------------------------------------------------- provisioning
class Prov {
  static final running = <String>{};
  static final tick = ValueNotifier<int>(0);

  static void log(Map s, String m) {
    final l = List<String>.from((s['log'] as List?) ?? []);
    final t = DateTime.now().toIso8601String().substring(11, 19);
    l.add('$t $m');
    s['log'] = l.length > 15 ? l.sublist(l.length - 15) : l;
    Store.save();
    tick.value++;
  }

  static String cloudInit(String pass) => '''#cloud-config
runcmd:
  - echo 'root:$pass' | chpasswd
  - printf 'PasswordAuthentication yes\\nPermitRootLogin yes\\n' > /etc/ssh/sshd_config.d/00-panel.conf
  - systemctl restart ssh
''';

  static Future<void> run3x(Map s, String ip, String pass) async {
    final user = 'u${randHex(3)}';
    final pw = randPass(14);
    final port = 20000 + _rnd.nextInt(30000);
    final base = randPass(12);
    log(s, 'تثبيت 3X-UI (قد ياخذ 1-4 دقائق)...');
    final inst = r"""
export DEBIAN_FRONTEND=noninteractive
for i in 1 2 3; do
  yes '' | timeout 900 bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) && break
  sleep 10
done
test -x /usr/local/x-ui/x-ui
""" +
        'U=$user\nP=$pw\nPORT=$port\nBASE=$base\n' +
        r"""
/usr/local/x-ui/x-ui setting -username $U -password $P -port $PORT -webBasePath /$BASE
systemctl restart x-ui
sleep 4
systemctl is-active x-ui
if curl -sk -o /dev/null --max-time 5 https://127.0.0.1:$PORT/; then echo SCHEME=https; else echo SCHEME=http; fi
""";
    final o1 = await Ssh.run(ip, pass, 'cat > /tmp/job.sh && bash /tmp/job.sh; rc=\$?; rm -f /tmp/job.sh; exit \$rc', input: inst);
    final scheme = o1.contains('SCHEME=https') ? 'https' : 'http';
    s['panel'] = {
      'url': '$scheme://$ip:$port/$base/',
      'user': user,
      'pass': pw,
    };
    await Store.save();
    log(s, 'توليد المفاتيح...');
    final out = await Ssh.run(
        ip,
        pass,
        r"""XB=$(ls /usr/local/x-ui/bin/xray-linux-* | head -1)
echo '===X25519==='; $XB x25519
echo '===VLESSENC==='; $XB vlessenc""");
    final k = Xray.parse(out);
    final x = <String, dynamic>{
      'port': 443,
      'sni': 'telegram.org',
      'target': 'core.telegram.org:443',
      'prv': k['prv'],
      'pbk': k['pbk'],
      'dec': k['dec'],
      'enc': k['enc'],
      'sids': [randHex(6), randHex(4), randHex(8)],
      'spx': '/${randHex(8)}',
    };
    final first = {
      'id': uuid4(),
      'email': 'user1',
      'created': DateTime.now().millisecondsSinceEpoch
    };
    final settings = {
      'clients': [
        {
          'id': first['id'],
          'flow': '',
          'email': 'user1',
          'limitIp': 0,
          'totalGB': 0,
          'expiryTime': 0,
          'enable': true,
          'tgId': '',
          'subId': randHex(8),
          'comment': '',
          'reset': 0
        }
      ],
      'decryption': x['dec'],
      'encryption': x['enc'],
      'fallbacks': [],
    };
    final stream = {
      'network': 'tcp',
      'security': 'reality',
      'externalProxy': [],
      'realitySettings': {
        'show': false,
        'xver': 0,
        'target': x['target'],
        'serverNames': [x['sni']],
        'privateKey': x['prv'],
        'minClientVer': '',
        'maxClientVer': '',
        'maxTimediff': 0,
        'shortIds': x['sids'],
        'mldsa65Seed': '',
        'settings': {
          'publicKey': x['pbk'],
          'fingerprint': 'chrome',
          'serverName': '',
          'spiderX': x['spx'],
          'mldsa65Verify': ''
        }
      },
      'tcpSettings': {
        'acceptProxyProtocol': false,
        'header': {'type': 'none'}
      }
    };
    final sniff = {
      'enabled': true,
      'destOverride': ['http', 'tls', 'quic'],
      'metadataOnly': false,
      'routeOnly': false
    };
    final add = 'U=$user\nP=$pw\nPORT=$port\nBASE=$base\nSCHEME=$scheme\n'
            "cat > /tmp/s.json <<'JEOF'\n${jsonEncode(settings)}\nJEOF\n"
            "cat > /tmp/ss.json <<'JEOF'\n${jsonEncode(stream)}\nJEOF\n"
            "cat > /tmp/sn.json <<'JEOF'\n${jsonEncode(sniff)}\nJEOF\n" +
        r"""
B=$SCHEME://127.0.0.1:$PORT/$BASE
curl -sk -c /tmp/cj.txt -d "username=$U" -d "password=$P" $B/login >/dev/null
curl -sk -b /tmp/cj.txt $B/panel/api/inbounds/add \
  --data-urlencode "settings@/tmp/s.json" \
  --data-urlencode "streamSettings@/tmp/ss.json" \
  --data-urlencode "sniffing@/tmp/sn.json" \
  -d remark=vless-reality -d enable=true -d listen= -d port=443 -d protocol=vless \
  -d up=0 -d down=0 -d total=0 -d expiryTime=0
echo
rm -f /tmp/s.json /tmp/ss.json /tmp/sn.json /tmp/cj.txt
sleep 12
""";
    final r = await Ssh.run(ip, pass, 'cat > /tmp/job.sh && bash /tmp/job.sh; rc=\$?; rm -f /tmp/job.sh; exit \$rc', input: add);
    s['xray'] = x;
    s['clients'] = [first];
    if (r.contains('"success":true')) {
      log(s, 'تم إنشاء الوارد داخل اللوحة');
    } else {
      log(s, 'تنبيه: ما انضاف الوارد تلقائياً، أنشئه من اللوحة. ${r.trim()}');
      s['clients'] = <dynamic>[];
      s.remove('xray');
    }
  }

  static Future<void> run(String id) async {
    if (running.contains(id)) return;
    final s = Store.servers[id];
    if (s == null) return;
    running.add(id);
    try {
      if (s['ip'] == null) {
        log(s, 'انتظار تشغيل السيرفر...');
        for (var i = 0; i < 60 && s['ip'] == null; i++) {
          await Future.delayed(const Duration(seconds: 5));
          final d = (await DO.req('GET', '/droplets/$id'))['droplet'];
          final ip = ipOf(d);
          if (d['status'] == 'active' && ip != 'pending') s['ip'] = ip;
        }
        if (s['ip'] == null) throw Exception('انتهت مهلة انتظار الـ IP');
        await Store.save();
      }
      final ip = s['ip'] as String;
      final pass = s['pass'] as String;
      log(s, 'IP: $ip — انتظار SSH...');
      var up = false;
      for (var i = 0; i < 48 && !up; i++) {
        try {
          await Ssh.run(ip, pass, 'true');
          up = true;
        } catch (_) {
          await Future.delayed(const Duration(seconds: 5));
        }
      }
      if (!up) throw Exception('تعذر الاتصال بـ SSH');
      if (s['mode'] == '3xui') {
        await run3x(s, ip, pass);
      } else {
        log(s, 'تثبيت Xray وتوليد المفاتيح (قد ياخذ دقيقة)...');
        final out = await Ssh.run(ip, pass, Xray.setup);
        final k = Xray.parse(out);
        final x = <String, dynamic>{
          'port': 443,
          'sni': 'telegram.org',
          'target': 'core.telegram.org:443',
          'prv': k['prv'],
          'pbk': k['pbk'],
          'dec': k['dec'],
          'enc': k['enc'],
          'sids': [randHex(6), randHex(4), randHex(8)],
          'spx': '/${randHex(8)}',
        };
        final first = {
          'id': uuid4(),
          'email': 'user1',
          'created': DateTime.now().millisecondsSinceEpoch
        };
        s['xray'] = x;
        log(s, 'كتابة الإعدادات وتشغيل Xray...');
        await Xray.apply(s, [first]);
        s['clients'] = [first];
      }
      s['status'] = 'ready';
      if (s['mode'] == '3xui' && s['panel'] != null) {
        Store.addPanel('${s['name']}', '${s['panel']['url']}',
            '${s['panel']['user']}', '${s['panel']['pass']}');
      }
      log(s, 'جاهز ✔');
    } catch (e) {
      s['status'] = 'error';
      s.remove('xray');
      log(s, 'خطأ: ${DO.msg(e)}');
    } finally {
      running.remove(id);
      await Store.save();
      tick.value++;
    }
  }
}

// ---------------------------------------------------------------- Home
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  bool loading = false;
  String? err;
  String balance = '';
  List<dynamic> droplets = [];
  List<int> keys = [];
  Map<int, String> pings = {};
  final tokenCtl = TextEditingController();

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    Prov.tick.addListener(_onTick);
    init();
  }

  @override
  void dispose() {
    Prov.tick.removeListener(_onTick);
    super.dispose();
  }

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    DO.token = p.getString('token') ?? '';
    await Store.load();
    if (mounted) setState(() {});
    if (DO.token.isNotEmpty) await refresh();
  }

  Future<void> refresh() async {
    if (DO.token.isEmpty) return;
    setState(() {
      loading = true;
      err = null;
    });
    try {
      final j = await DO.req('GET', '/droplets?per_page=200');
      droplets = j['droplets'] as List;
      final ids = droplets.map((d) => '${d['id']}').toSet();
      Store.servers.removeWhere((k, v) => !ids.contains(k));
      await Store.save();
      for (final e in Store.servers.entries) {
        if (e.value['status'] == 'creating') Prov.run(e.key);
      }
      final k = await DO.req('GET', '/account/keys');
      keys = (k['ssh_keys'] as List).map<int>((e) => e['id'] as int).toList();
      try {
        final b = await DO.req('GET', '/customers/my/balance');
        balance = '\$${b['month_to_date_usage']}';
      } catch (_) {}
    } catch (e) {
      err = DO.msg(e);
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> saveToken() async {
    final v = tokenCtl.text.trim();
    if (v.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('token', v);
    DO.token = v;
    tokenCtl.clear();
    setState(() => tab = 1);
    await refresh();
  }

  Future<void> clearToken() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('token');
    DO.token = '';
    setState(() {
      droplets = [];
      balance = '';
    });
    if (mounted) snack(context, 'تم مسح التوكن');
  }

  Future<void> doPing(int id, String ip, int port) async {
    if (ip == 'pending') {
      snack(context, 'السيرفر لسه ما جاهز');
      return;
    }
    setState(() => pings[id] = 'جاري الفحص...');
    final r = await avgPing(ip, port);
    setState(() => pings[id] = r == null ? 'ما كو استجابة' : 'التأخير: $r ms');
  }

  Future<void> del(int id, String name) async {
    if (!await confirm(context, 'حذف السيرفر $name ؟')) return;
    try {
      await DO.req('DELETE', '/droplets/$id');
      Store.servers.remove('$id');
      await Store.save();
      if (mounted) snack(context, 'تم الحذف');
      await refresh();
    } catch (e) {
      if (mounted) snack(context, DO.msg(e));
    }
  }

  Future<void> reboot(int id) async {
    if (!await confirm(context, 'إعادة تشغيل السيرفر؟')) return;
    try {
      await DO.req('POST', '/droplets/$id/actions', {'type': 'reboot'});
      if (mounted) snack(context, 'تم إرسال الأمر');
    } catch (e) {
      if (mounted) snack(context, DO.msg(e));
    }
  }

  void copy(String s) {
    Clipboard.setData(ClipboardData(text: s));
    snack(context, 'تم النسخ');
  }

  Widget card(dynamic d) {
    final id = d['id'] as int;
    final ip = ipOf(d);
    final active = d['status'] == 'active';
    final local = Store.servers['$id'];
    final st = local?['status'] as String?;
    final ready = st == 'ready';
    final port = ready ? (local!['xray']['port'] as int) : 22;
    final logs = List<String>.from((local?['log'] as List?) ?? []);
    final stText = st == 'creating'
        ? 'جاري التجهيز'
        : st == 'error'
            ? 'فشل التجهيز'
            : '${d['status']}';
    final stColor = st == 'error'
        ? Colors.redAccent
        : (active && st != 'creating' ? Colors.greenAccent : Colors.orangeAccent);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('${d['name']}',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold))),
            Text(stText, style: TextStyle(color: stColor)),
          ]),
          Text('${d['region']['slug']}  •  ${d['size_slug']}'
              '${ready ? '  •  ${(local!['clients'] as List).length} مستخدم' : ''}'),
          const SizedBox(height: 6),
          SelectableText(ip,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          if (pings[id] != null) Text(pings[id]!),
          if (ready && local!['panel'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(
                  'اللوحة: ${local['panel']['url']}\nاليوزر: ${local['panel']['user']}   الباسورد: ${local['panel']['pass']}',
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontSize: 12)),
            ),
          if (!ready && logs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(logs.join('\n'),
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            if (ready && (local!['clients'] as List).isNotEmpty)
              FilledButton(
                  onPressed: () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => ClientsPage(id: '$id')));
                    if (mounted) setState(() {});
                  },
                  child: const Text('المستخدمون')),
            if (ready && local!['panel'] != null)
              FilledButton(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => PanelPage(panel: {
                                'name': '${d['name']}',
                                'url': '${local['panel']['url']}',
                                'user': '${local['panel']['user']}',
                                'pass': '${local['panel']['pass']}',
                              }))),
                  child: const Text('فتح اللوحة')),
            if (ready && local!['panel'] != null)
              OutlinedButton(
                  onPressed: () => copy('${local['panel']['pass']}'),
                  child: const Text('نسخ باسورد اللوحة')),
            if (st == 'error')
              FilledButton(
                  onPressed: () {
                    local!['status'] = 'creating';
                    Store.save();
                    Prov.run('$id');
                    setState(() {});
                  },
                  child: const Text('إعادة المحاولة')),
            OutlinedButton(
                onPressed: () => doPing(id, ip, port),
                child: const Text('فحص التأخير')),
            OutlinedButton(onPressed: () => copy(ip), child: const Text('نسخ IP')),
            if (local != null)
              OutlinedButton(
                  onPressed: () => copy('ssh root@$ip'),
                  child: const Text('نسخ SSH')),
            if (local != null)
              OutlinedButton(
                  onPressed: () => copy('${local['pass']}'),
                  child: const Text('نسخ باسورد root')),
            OutlinedButton(
                onPressed: () => reboot(id), child: const Text('إعادة تشغيل')),
            FilledButton.tonal(
                style: FilledButton.styleFrom(foregroundColor: Colors.redAccent),
                onPressed: () => del(id, '${d['name']}'),
                child: const Text('حذف')),
          ]),
        ]),
      ),
    );
  }

  Future<void> addPanel() async {
    final n = TextEditingController();
    final u = TextEditingController();
    final us = TextEditingController();
    final pw = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (x) => AlertDialog(
              title: const Text('إضافة لوحة 3X-UI'),
              content: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: n,
                      decoration: const InputDecoration(labelText: 'الاسم')),
                  TextField(
                      controller: u,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                          labelText: 'رابط اللوحة الكامل',
                          hintText: 'http://IP:PORT/PATH/')),
                  TextField(
                      controller: us,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(labelText: 'اليوزر')),
                  TextField(
                      controller: pw,
                      obscureText: true,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(labelText: 'الباسورد')),
                ]),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(x, false),
                    child: const Text('إلغاء')),
                TextButton(
                    onPressed: () => Navigator.pop(x, true),
                    child: const Text('حفظ')),
              ],
            ));
    if (ok != true) return;
    if (u.text.trim().isEmpty || us.text.trim().isEmpty || pw.text.isEmpty) {
      if (mounted) snack(context, 'عبّي الرابط واليوزر والباسورد');
      return;
    }
    final url = Panels.norm(u.text);
    Store.panels.add({
      'name': n.text.trim().isEmpty ? url : n.text.trim(),
      'url': url,
      'user': us.text.trim(),
      'pass': pw.text,
    });
    await Store.save();
    if (mounted) setState(() {});
  }

  Widget panelsTab() {
    return ListView(padding: const EdgeInsets.all(12), children: [
      FilledButton.icon(
          onPressed: addPanel,
          icon: const Icon(Icons.add),
          label: const Text('إضافة لوحة 3X-UI')),
      const SizedBox(height: 8),
      if (Store.panels.isEmpty)
        const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
                child: Text('ما كو لوحات. أضف رابط لوحتك أو أنشئ سيرفر جديد',
                    textAlign: TextAlign.center))),
      ...Store.panels.asMap().entries.map((e) {
        final pn = e.value;
        return Card(
          child: ListTile(
            leading: const Icon(Icons.dashboard),
            title: Text('${pn['name']}'),
            subtitle: Text('${pn['url']}',
                textDirection: TextDirection.ltr,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => PanelPage(panel: Map<String, dynamic>.from(pn)))),
            trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (await confirm(context, 'حذف اللوحة من التطبيق؟')) {
                    Store.panels.removeAt(e.key);
                    await Store.save();
                    if (mounted) setState(() {});
                  }
                }),
          ),
        );
      }),
    ]);
  }

  Widget serversTab() {
    if (DO.token.isEmpty) {
      return const Center(child: Text('أدخل التوكن من تبويب الإعدادات'));
    }
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        if (loading) const LinearProgressIndicator(),
        if (err != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child:
                      Text(err!, style: const TextStyle(color: Colors.redAccent)))),
        if (!loading && err == null && droplets.isEmpty)
          const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('لا يوجد سيرفرات'))),
        ...droplets.map(card),
      ]),
    );
  }

  Widget settingsTab() => ListView(padding: const EdgeInsets.all(16), children: [
        const Text('توكن DigitalOcean',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
            controller: tokenCtl,
            obscureText: true,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), hintText: 'dop_v1_...')),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton(onPressed: saveToken, child: const Text('حفظ')),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: clearToken, child: const Text('مسح التوكن')),
        ]),
        const SizedBox(height: 12),
        const Text(
            'التوكن وباسوردات السيرفرات ومفاتيح Xray تُحفظ على جهازك فقط. لا ترسلها لأي أحد.',
            style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 12),
        Text('مفاتيح SSH بالحساب: ${keys.length}'),
      ]);

  @override
  Widget build(BuildContext context) {
    final pages = [
      panelsTab(),
      serversTab(),
      CreateTab(
          keys: keys,
          onCreated: () async {
            await refresh();
            if (mounted) setState(() => tab = 1);
          }),
      settingsTab(),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('إدارة السيرفرات'),
        actions: [
          if (balance.isNotEmpty)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(child: Text('هذا الشهر: $balance'))),
          IconButton(onPressed: refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SafeArea(child: pages[tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard), label: 'اللوحات'),
          NavigationDestination(icon: Icon(Icons.dns), label: 'السيرفرات'),
          NavigationDestination(icon: Icon(Icons.add_circle), label: 'إنشاء'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'الإعدادات'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- Clients
class ClientsPage extends StatefulWidget {
  final String id;
  const ClientsPage({super.key, required this.id});
  @override
  State<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends State<ClientsPage> {
  final name = TextEditingController();
  bool busy = false;
  Map<String, dynamic> get s => Store.servers[widget.id]!;
  List get clients => s['clients'] as List;
  bool get panelMode => s['mode'] == '3xui';

  Future<void> add() async {
    final n = name.text.trim();
    if (!RegExp(r'^[A-Za-z0-9._-]{1,40}$').hasMatch(n)) {
      snack(context, 'الاسم: حروف إنكليزية وأرقام فقط');
      return;
    }
    if (clients.any((c) => c['email'] == n)) {
      snack(context, 'الاسم مستخدم');
      return;
    }
    setState(() => busy = true);
    try {
      final c = {
        'id': uuid4(),
        'email': n,
        'created': DateTime.now().millisecondsSinceEpoch
      };
      final next = [...clients, c];
      await Xray.apply(s, next);
      s['clients'] = next;
      await Store.save();
      name.clear();
    } catch (e) {
      if (mounted) snack(context, DO.msg(e));
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> remove(Map c) async {
    if (clients.length <= 1) {
      snack(context, 'لازم يبقى مستخدم واحد على الأقل');
      return;
    }
    if (!await confirm(context, 'حذف ${c['email']} ؟')) return;
    setState(() => busy = true);
    try {
      final next = clients.where((k) => k['id'] != c['id']).toList();
      await Xray.apply(s, next);
      s['clients'] = next;
      await Store.save();
    } catch (e) {
      if (mounted) snack(context, DO.msg(e));
    }
    if (mounted) setState(() => busy = false);
  }

  void showQr(String l) {
    showDialog(
        context: context,
        builder: (x) => AlertDialog(
              content: SizedBox(
                width: 260,
                height: 260,
                child: QrImageView(
                    data: l,
                    size: 260,
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.L),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(x), child: const Text('إغلاق'))
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${s['ip']}')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(12), children: [
          if (busy) const LinearProgressIndicator(),
          ...clients.map((c) {
            final l = Xray.link(s, Map<String, dynamic>.from(c as Map));
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${c['email']}',
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      SelectableText(l,
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(fontSize: 11)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, children: [
                        FilledButton(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: l));
                              snack(context, 'تم النسخ');
                            },
                            child: const Text('نسخ')),
                        OutlinedButton(
                            onPressed: () => showQr(l),
                            child: const Text('QR')),
                        if (!panelMode)
                          FilledButton.tonal(
                              style: FilledButton.styleFrom(
                                  foregroundColor: Colors.redAccent),
                              onPressed: busy
                                  ? null
                                  : () => remove(Map<String, dynamic>.from(c)),
                              child: const Text('حذف')),
                      ]),
                    ]),
              ),
            );
          }),
          if (panelMode)
            const Padding(
                padding: EdgeInsets.all(8),
                child: Text('باقي المستخدمين وإعدادات الوارد تُدار من لوحة 3X-UI بالمتصفح.',
                    style: TextStyle(color: Colors.grey))),
          if (!panelMode) ...[
          const SizedBox(height: 8),
          TextField(
              controller: name,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'اسم مستخدم جديد (إنكليزي)')),
          const SizedBox(height: 8),
          FilledButton(
              onPressed: busy ? null : add, child: const Text('إضافة مستخدم')),
          ],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- Create
class CreateTab extends StatefulWidget {
  final List<int> keys;
  final Future<void> Function() onCreated;
  const CreateTab({super.key, required this.keys, required this.onCreated});
  @override
  State<CreateTab> createState() => _CreateTabState();
}

class _CreateTabState extends State<CreateTab> {
  static const regions = {
    'fra1': 'فرانكفورت',
    'lon1': 'لندن',
    'ams3': 'أمستردام',
    'blr1': 'بنغالور',
    'sgp1': 'سنغافورة',
    'nyc1': 'نيويورك',
    'tor1': 'تورنتو',
    'syd1': 'سيدني',
  };
  static const sizes = {
    's-1vcpu-512mb-10gb': '512MB - \$4',
    's-1vcpu-1gb': '1GB - \$6',
    's-1vcpu-2gb': '2GB - \$12',
  };

  String region = 'fra1';
  String size = 's-1vcpu-512mb-10gb';
  String mode = '3xui';
  final name = TextEditingController();
  Map<String, int?> res = {};
  bool testing = false;
  bool busy = false;
  String? msg;
  bool ok = false;

  Future<void> test() async {
    setState(() {
      testing = true;
      res = {};
    });
    final out = <String, int?>{};
    await Future.wait(regions.keys.map((r) async {
      out[r] = await avgPing('speedtest-$r.digitalocean.com', 80);
    }));
    if (mounted) {
      setState(() {
        res = out;
        testing = false;
      });
    }
  }

  Future<void> create() async {
    if (DO.token.isEmpty) {
      snack(context, 'أدخل التوكن أولًا');
      return;
    }
    final n = name.text.trim().isEmpty ? 'vpn-$region' : name.text.trim();
    if (!RegExp(r'^[A-Za-z0-9.-]{1,60}$').hasMatch(n)) {
      setState(() {
        ok = false;
        msg = 'الاسم: حروف إنكليزية وأرقام فقط';
      });
      return;
    }
    setState(() {
      busy = true;
      msg = null;
    });
    try {
      final pass = randPass(20);
      final body = <String, dynamic>{
        'name': n,
        'region': region,
        'size': size,
        'image': 'ubuntu-24-04-x64',
        'user_data': Prov.cloudInit(pass),
      };
      if (widget.keys.isNotEmpty) body['ssh_keys'] = widget.keys;
      final j = await DO.req('POST', '/droplets', body);
      final id = '${j['droplet']['id']}';
      Store.servers[id] = {
        'name': n,
        'region': region,
        'size': size,
        'ip': null,
        'pass': pass,
        'mode': mode,
        'status': 'creating',
        'log': <String>[],
      };
      await Store.save();
      Prov.run(id);
      ok = true;
      msg = 'تم الإنشاء. التجهيز التلقائي شغال، لا تغلق التطبيق لحد ما يصير جاهز.';
      await widget.onCreated();
    } catch (e) {
      ok = false;
      msg = DO.msg(e);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final sorted = res.entries.toList()
      ..sort((a, b) {
        if (a.value == null) return 1;
        if (b.value == null) return -1;
        return a.value!.compareTo(b.value!);
      });
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('فحص أقرب منطقة من جهازك',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      FilledButton.tonal(
          onPressed: testing ? null : test,
          child: Text(testing ? 'جاري الفحص...' : 'ابدأ الفحص')),
      ...sorted.map((e) => ListTile(
            dense: true,
            title: Text('${regions[e.key]} (${e.key})'),
            trailing: Text(e.value == null ? 'لا استجابة' : '${e.value} ms'),
            onTap: () => setState(() => region = e.key),
          )),
      const Divider(height: 32),
      const Text('إنشاء سيرفر جديد (مع VLESS جاهز)',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        value: region,
        decoration: const InputDecoration(
            border: OutlineInputBorder(), labelText: 'المنطقة'),
        items: regions.entries
            .map((e) => DropdownMenuItem(
                value: e.key, child: Text('${e.value} (${e.key})')))
            .toList(),
        onChanged: (v) => setState(() => region = v!),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        value: size,
        decoration: const InputDecoration(
            border: OutlineInputBorder(), labelText: 'الحجم'),
        items: sizes.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: (v) => setState(() => size = v!),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        value: mode,
        decoration: const InputDecoration(
            border: OutlineInputBorder(), labelText: 'نوع التجهيز'),
        items: const [
          DropdownMenuItem(
              value: '3xui', child: Text('3X-UI (لوحة بالمتصفح + VLESS جاهز)')),
          DropdownMenuItem(value: 'xray', child: Text('Xray مباشر (من التطبيق)')),
        ],
        onChanged: (v) => setState(() => mode = v!),
      ),
      const SizedBox(height: 12),
      TextField(
          controller: name,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
              border: OutlineInputBorder(), labelText: 'الاسم (اختياري)')),
      const SizedBox(height: 12),
      FilledButton(
          onPressed: busy ? null : create,
          child: Text(busy ? 'جاري الإنشاء...' : 'إنشاء السيرفر')),
      const SizedBox(height: 8),
      const Text(
          'بعد الإنشاء التطبيق يدخل السيرفر بـSSH ويجهّزه تلقائياً. بوضع 3X-UI تحصل رابط اللوحة ويوزرها وباسوردها ورابط VLESS جاهز خلال 3-6 دقائق.',
          style: TextStyle(color: Colors.grey, fontSize: 13)),
      if (msg != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(msg!,
              style: TextStyle(color: ok ? Colors.greenAccent : Colors.redAccent)),
        ),
    ]);
  }
}


// ---------------------------------------------------------------- 3X-UI panel (WebView)
class Panels {
  static String norm(String u) {
    var s = u.trim();
    if (!s.startsWith('http')) s = 'http://$s';
    s = s.replaceFirst(RegExp(r'panel/?$'), '');
    if (!s.endsWith('/')) s += '/';
    return s;
  }

  static Future<List<Cookie>> login(String base, String user, String pass) async {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 10);
    c.badCertificateCallback = (cert, host, port) => true;
    try {
      final req = await c.postUrl(Uri.parse('${base}login'));
      req.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      req.write(
          'username=${Uri.encodeQueryComponent(user)}&password=${Uri.encodeQueryComponent(pass)}');
      final res = await req.close();
      final body = await utf8.decodeStream(res);
      if (!body.contains('"success":true')) {
        throw Exception('بيانات الدخول غير صحيحة أو اللوحة ما استجابت');
      }
      return res.cookies;
    } finally {
      c.close(force: true);
    }
  }
}

class PanelPage extends StatefulWidget {
  final Map<String, dynamic> panel;
  const PanelPage({super.key, required this.panel});
  @override
  State<PanelPage> createState() => _PanelPageState();
}

class _PanelPageState extends State<PanelPage> {
  late final WebViewController c;
  bool loading = true;
  String? note;

  @override
  void initState() {
    super.initState();
    c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => loading = false);
        },
        onSslAuthError: (r) => r.proceed(),
      ));
    start();
  }

  Future<void> start() async {
    final base = Panels.norm('${widget.panel['url']}');
    final uri = Uri.parse(base);
    try {
      final cookies = await Panels.login(
          base, '${widget.panel['user']}', '${widget.panel['pass']}');
      for (final k in cookies) {
        await WebViewCookieManager().setCookie(WebViewCookie(
            name: k.name,
            value: k.value,
            domain: uri.host,
            path: k.path ?? '/'));
      }
    } catch (e) {
      note = DO.msg(e);
    }
    await c.loadRequest(Uri.parse('${base}panel/'));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await c.canGoBack()) {
          c.goBack();
        } else if (context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${widget.panel['name']}'),
          actions: [
            IconButton(onPressed: () => c.reload(), icon: const Icon(Icons.refresh)),
          ],
        ),
        body: SafeArea(
          child: Column(children: [
            if (loading) const LinearProgressIndicator(),
            if (note != null)
              Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('تعذر الدخول التلقائي: $note',
                      style: const TextStyle(color: Colors.orangeAccent))),
            Expanded(child: WebViewWidget(controller: c)),
          ]),
        ),
      ),
    );
  }
}
