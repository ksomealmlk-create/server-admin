import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
      throw Exception(j is Map ? (j['message'] ?? 'HTTP ${r.statusCode}') : 'HTTP ${r.statusCode}');
    }
    return Map<String, dynamic>.from(j as Map);
  }

  static String msg(Object e) => e.toString().replaceFirst('Exception: ', '');
}

Future<int?> tcpPing(String host, int port) async {
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(host, port,
        timeout: const Duration(seconds: 3));
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

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    DO.token = p.getString('token') ?? '';
    if (DO.token.isEmpty) {
      setState(() => tab = 2);
    } else {
      await refresh();
    }
  }

  Future<void> refresh() async {
    if (DO.token.isEmpty) return;
    setState(() {
      loading = true;
      err = null;
    });
    try {
      final j = await DO.req('GET', '/droplets');
      droplets = j['droplets'] as List;
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
    setState(() => tab = 0);
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

  Future<void> doPing(int id, String ip) async {
    if (ip == 'pending') {
      snack(context, 'السيرفر لسه ما جاهز');
      return;
    }
    setState(() => pings[id] = 'جاري الفحص...');
    final r = await avgPing(ip, 22);
    setState(() => pings[id] = r == null ? 'ما كو استجابة' : 'التأخير: $r ms');
  }

  Future<void> del(int id, String name) async {
    if (!await confirm(context, 'حذف السيرفر $name ؟')) return;
    try {
      await DO.req('DELETE', '/droplets/$id');
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('${d['name']}',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold))),
            Text('${d['status']}',
                style: TextStyle(
                    color: active ? Colors.greenAccent : Colors.orangeAccent)),
          ]),
          Text('${d['region']['slug']}  •  ${d['size_slug']}'),
          const SizedBox(height: 6),
          SelectableText(ip,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          if (pings[id] != null) Text(pings[id]!),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            FilledButton(
                onPressed: () => doPing(id, ip), child: const Text('فحص التأخير')),
            OutlinedButton(onPressed: () => copy(ip), child: const Text('نسخ IP')),
            OutlinedButton(
                onPressed: () => copy('ssh root@$ip'),
                child: const Text('نسخ SSH')),
            OutlinedButton(
                onPressed: () => reboot(id), child: const Text('إعادة تشغيل')),
            FilledButton.tonal(
                style: FilledButton.styleFrom(
                    foregroundColor: Colors.redAccent),
                onPressed: () => del(id, '${d['name']}'),
                child: const Text('حذف')),
          ]),
        ]),
      ),
    );
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
                  child: Text(err!,
                      style: const TextStyle(color: Colors.redAccent)))),
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
        const Text('التوكن يُحفظ على جهازك فقط. لا ترسله لأي أحد.',
            style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 12),
        Text('مفاتيح SSH بالحساب: ${keys.length}'),
      ]);

  @override
  Widget build(BuildContext context) {
    final pages = [
      serversTab(),
      CreateTab(keys: keys, onCreated: refresh),
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
          NavigationDestination(icon: Icon(Icons.dns), label: 'السيرفرات'),
          NavigationDestination(icon: Icon(Icons.add_circle), label: 'إنشاء'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'الإعدادات'),
        ],
      ),
    );
  }
}

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
  static const xui =
      'bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)';

  String region = 'fra1';
  String size = 's-1vcpu-512mb-10gb';
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
    setState(() {
      busy = true;
      msg = null;
    });
    try {
      final body = <String, dynamic>{
        'name': name.text.trim().isEmpty ? 'vpn-$region' : name.text.trim(),
        'region': region,
        'size': size,
        'image': 'ubuntu-24-04-x64',
      };
      if (widget.keys.isNotEmpty) body['ssh_keys'] = widget.keys;
      final j = await DO.req('POST', '/droplets', body);
      ok = true;
      msg = 'تم الإنشاء (ID: ${j['droplet']['id']}). افتح تبويب السيرفرات بعد دقيقة لترى الـ IP.' +
          (widget.keys.isEmpty ? '\nما كو مفتاح SSH بحسابك، راح يوصلك باسوورد root بالإيميل.' : '');
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
      const Text('إنشاء سيرفر جديد',
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
      TextField(
          controller: name,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
              border: OutlineInputBorder(), labelText: 'الاسم (اختياري)')),
      const SizedBox(height: 12),
      FilledButton(
          onPressed: busy ? null : create,
          child: Text(busy ? 'جاري الإنشاء...' : 'إنشاء السيرفر')),
      if (msg != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(msg!,
              style: TextStyle(
                  color: ok ? Colors.greenAccent : Colors.redAccent)),
        ),
      const Divider(height: 32),
      const Text('تثبيت لوحة 3x-ui (نفّذه بالـ SSH بعد الإنشاء)',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      SelectableText(xui,
          textDirection: TextDirection.ltr,
          style: const TextStyle(fontSize: 12)),
      OutlinedButton(
          onPressed: () {
            Clipboard.setData(const ClipboardData(text: xui));
            snack(context, 'تم النسخ');
          },
          child: const Text('نسخ الأمر')),
    ]);
  }
}
