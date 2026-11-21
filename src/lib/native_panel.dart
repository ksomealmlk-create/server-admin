import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

// ------------------------------------------------------------ helpers
final _rng = Random.secure();

String _uuid() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

String _rid(int n) {
  const cs = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(n, (_) => cs[_rng.nextInt(cs.length)]).join();
}

num _n(dynamic v) => v is num ? v : (num.tryParse('$v') ?? 0);

String _bytes(num b) {
  if (b < 1024) return '${b.toStringAsFixed(0)} B';
  const u = ['KB', 'MB', 'GB', 'TB'];
  double v = b / 1024;
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 2 : 1)} ${u[i]}';
}

String _uptime(num s) {
  final d = s ~/ 86400;
  final h = (s % 86400) ~/ 3600;
  final m = (s % 3600) ~/ 60;
  return d > 0 ? '$dي $hس' : '$hس $mد';
}

String _expiry(num ms) {
  if (ms == 0) return 'بدون انتهاء';
  final d = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
  final left = d.difference(DateTime.now()).inDays;
  final ds = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  return left < 0 ? 'منتهي ($ds)' : '$ds (باقي $left يوم)';
}

String _err(Object e) => e.toString().replaceFirst('Exception: ', '');

void _snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

Future<bool> _confirm(BuildContext c, String t) async =>
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

// ------------------------------------------------------------ API
class XApi {
  final String base; // ends with '/'
  final String token;
  XApi(this.base, this.token);

  Future<Map<String, dynamic>> _req(String method, String path,
      {Object? body}) async {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 12);
    c.badCertificateCallback = (cert, host, port) => true;
    try {
      final req = await c.openUrl(method, Uri.parse('$base$path'));
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.set('Accept', 'application/json');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(const Duration(seconds: 30));
      final txt = await utf8.decodeStream(res);
      if (res.statusCode == 401 ||
          res.statusCode == 403 ||
          res.statusCode == 404) {
        throw Exception(
            'تعذر الوصول (${res.statusCode}): تأكد من التوكن ومن رابط اللوحة');
      }
      dynamic j;
      try {
        j = jsonDecode(txt);
      } catch (_) {
        throw Exception('رد غير متوقع من اللوحة (HTTP ${res.statusCode})');
      }
      if (j is! Map) throw Exception('رد غير متوقع من اللوحة');
      final m = Map<String, dynamic>.from(j);
      if (m['success'] == false) throw Exception('${m['msg'] ?? 'فشل الطلب'}');
      return m;
    } finally {
      c.close(force: true);
    }
  }

  Future<Map<String, dynamic>> get(String p) => _req('GET', p);
  Future<Map<String, dynamic>> post(String p, [Object? body]) =>
      _req('POST', p, body: body ?? <String, dynamic>{});
}

// ------------------------------------------------------------ page
class NativePanelPage extends StatefulWidget {
  final Map<String, dynamic> panel;
  final VoidCallback openWeb;
  const NativePanelPage({super.key, required this.panel, required this.openWeb});
  @override
  State<NativePanelPage> createState() => _NativePanelPageState();
}

class _NativePanelPageState extends State<NativePanelPage>
    with SingleTickerProviderStateMixin {
  late final XApi api;
  late final TabController tabs;
  Timer? timer;

  Map<String, dynamic>? status;
  String? statusErr;
  List<dynamic> inbounds = [];
  String? inbErr;
  List<Map<String, dynamic>> clients = [];
  Set<String> onlines = {};
  String? cliErr;
  bool loadingCli = false;
  String filter = '';

  @override
  void initState() {
    super.initState();
    var b = '${widget.panel['url']}'.trim();
    if (!b.endsWith('/')) b += '/';
    api = XApi(b, '${widget.panel['token']}');
    tabs = TabController(length: 3, vsync: this);
    loadStatus();
    loadInbounds();
    loadClients();
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (tabs.index == 0 && !tabs.indexIsChanging) loadStatus();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    tabs.dispose();
    super.dispose();
  }

  Future<void> loadStatus() async {
    try {
      final m = await api.get('panel/api/server/status');
      if (!mounted) return;
      setState(() {
        status = Map<String, dynamic>.from((m['obj'] as Map?) ?? {});
        statusErr = null;
      });
    } catch (e) {
      if (mounted) setState(() => statusErr = _err(e));
    }
  }

  Future<void> loadInbounds() async {
    try {
      final m = await api.get('panel/api/inbounds/list');
      if (!mounted) return;
      setState(() {
        inbounds = (m['obj'] as List?) ?? [];
        inbErr = null;
      });
    } catch (e) {
      if (mounted) setState(() => inbErr = _err(e));
    }
  }

  Future<void> loadClients() async {
    setState(() => loadingCli = true);
    try {
      final list = <Map<String, dynamic>>[];
      var page = 1;
      while (page <= 25) {
        final m = await api.get(
            'panel/api/clients/list/paged?page=$page&pageSize=200&sort=email');
        final obj = m['obj'];
        final items = obj is Map ? (obj['items'] as List?) : (obj as List?);
        final got = (items ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        list.addAll(got);
        final filtered = obj is Map ? _n(obj['filtered']).toInt() : list.length;
        if (got.isEmpty || list.length >= filtered) break;
        page++;
      }
      Set<String> on = {};
      try {
        final o = await api.post('panel/api/clients/onlines');
        on = ((o['obj'] as List?) ?? []).map((e) => '$e').toSet();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        clients = list;
        onlines = on;
        cliErr = null;
      });
    } catch (e) {
      if (mounted) setState(() => cliErr = _err(e));
    }
    if (mounted) setState(() => loadingCli = false);
  }

  // ---- actions
  Future<void> restartXray() async {
    if (!await _confirm(context, 'إعادة تشغيل Xray؟')) return;
    try {
      await api.post('panel/api/server/restartXrayService');
      if (mounted) _snack(context, 'تمت إعادة التشغيل');
      loadStatus();
    } catch (e) {
      if (mounted) _snack(context, _err(e));
    }
  }

  Future<Map<String, dynamic>> fetchClient(String email) async {
    final m = await api.get('panel/api/clients/get/${Uri.encodeComponent(email)}');
    final o = Map<String, dynamic>.from(m['obj'] as Map);
    return Map<String, dynamic>.from((o['client'] ?? o) as Map);
  }

  Future<void> toggle(String email, bool v) async {
    try {
      await api.post(
          v ? 'panel/api/clients/bulkEnable' : 'panel/api/clients/bulkDisable',
          {'emails': [email]});
      await loadClients();
    } catch (e) {
      if (mounted) _snack(context, _err(e));
    }
  }

  Future<void> resetTraffic(String email) async {
    if (!await _confirm(context, 'تصفير استهلاك $email ؟')) return;
    try {
      await api.post('panel/api/clients/resetTraffic/${Uri.encodeComponent(email)}');
      await loadClients();
    } catch (e) {
      if (mounted) _snack(context, _err(e));
    }
  }

  Future<void> delClient(String email) async {
    if (!await _confirm(context, 'حذف $email ؟')) return;
    try {
      await api.post('panel/api/clients/del/${Uri.encodeComponent(email)}');
      await loadClients();
    } catch (e) {
      if (mounted) _snack(context, _err(e));
    }
  }

  Future<void> showLinks(String email) async {
    try {
      final m = await api.get('panel/api/clients/links/${Uri.encodeComponent(email)}');
      final o = m['obj'];
      final links = o is List ? o.map((e) => '$e').toList() : ['$o'];
      if (!mounted) return;
      await showDialog(
          context: context,
          builder: (x) => AlertDialog(
                title: Text(email),
                content: SizedBox(
                  width: 320,
                  child: SingleChildScrollView(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: links
                            .map((l) => Padding(
                                  padding: const EdgeInsets.only(bottom: 14),
                                  child: Column(children: [
                                    SizedBox(
                                      width: 240,
                                      height: 240,
                                      child: QrImageView(
                                          data: l,
                                          size: 240,
                                          backgroundColor: Colors.white,
                                          errorCorrectionLevel:
                                              QrErrorCorrectLevel.L),
                                    ),
                                    const SizedBox(height: 6),
                                    SelectableText(l,
                                        textDirection: TextDirection.ltr,
                                        style: const TextStyle(fontSize: 11)),
                                    TextButton(
                                        onPressed: () {
                                          Clipboard.setData(ClipboardData(text: l));
                                          _snack(context, 'تم النسخ');
                                        },
                                        child: const Text('نسخ الرابط')),
                                  ]),
                                ))
                            .toList()),
                  ),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(x), child: const Text('إغلاق'))
                ],
              ));
    } catch (e) {
      if (mounted) _snack(context, _err(e));
    }
  }

  Future<void> editLimits(Map<String, dynamic> c) async {
    final email = '${c['email']}';
    final totalB = _n(c['totalGB']);
    final gb = TextEditingController(
        text: totalB == 0 ? '0' : (totalB / 1073741824).toStringAsFixed(1));
    final days = TextEditingController(text: '');
    final ok = await showDialog<bool>(
        context: context,
        builder: (x) => AlertDialog(
              title: Text('حدود $email'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: gb,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'الحجم بالـGB (0 = بلا حد)')),
                TextField(
                    controller: days,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'المدة من اليوم بالأيام (0 = بلا انتهاء، فارغ = بدون تغيير)')),
              ]),
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
    try {
      final cur = await fetchClient(email);
      final g = double.tryParse(gb.text.trim()) ?? 0;
      cur['totalGB'] = (g * 1073741824).round();
      if (days.text.trim().isNotEmpty) {
        final d = int.tryParse(days.text.trim()) ?? 0;
        cur['expiryTime'] = d == 0
            ? 0
            : DateTime.now().add(Duration(days: d)).millisecondsSinceEpoch;
      }
      await api.post('panel/api/clients/update/${Uri.encodeComponent(email)}', cur);
      await loadClients();
    } catch (e) {
      if (mounted) _snack(context, _err(e));
    }
  }

  Future<void> addClient() async {
    if (inbounds.isEmpty) {
      _snack(context, 'ما كو واردات. أنشئ وارداً من اللوحة الأصلية أولاً');
      return;
    }
    final email = TextEditingController();
    final gb = TextEditingController(text: '0');
    final days = TextEditingController(text: '0');
    final ips = TextEditingController(text: '0');
    dynamic inb = inbounds.first['id'];
    final ok = await showDialog<bool>(
        context: context,
        builder: (x) => StatefulBuilder(
              builder: (x, setS) => AlertDialog(
                title: const Text('إضافة عميل'),
                content: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: email,
                        textDirection: TextDirection.ltr,
                        decoration: const InputDecoration(
                            labelText: 'الاسم (إنكليزي بدون مسافات)')),
                    DropdownButtonFormField<dynamic>(
                      value: inb,
                      decoration: const InputDecoration(labelText: 'الوارد'),
                      items: inbounds
                          .map((i) => DropdownMenuItem<dynamic>(
                              value: i['id'],
                              child: Text('${i['remark'] ?? i['id']} (${i['port']})')))
                          .toList(),
                      onChanged: (v) => setS(() => inb = v),
                    ),
                    TextField(
                        controller: gb,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'الحجم بالـGB (0 = بلا حد)')),
                    TextField(
                        controller: days,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'المدة بالأيام (0 = بلا انتهاء)')),
                    TextField(
                        controller: ips,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'حد الأجهزة (0 = بلا حد)')),
                  ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(x, false),
                      child: const Text('إلغاء')),
                  TextButton(
                      onPressed: () => Navigator.pop(x, true),
                      child: const Text('إضافة')),
                ],
              ),
            ));
    if (ok != true) return;
    final name = email.text.trim();
    if (!RegExp(r'^[A-Za-z0-9._-]{1,40}$').hasMatch(name)) {
      if (mounted) _snack(context, 'الاسم: حروف إنكليزية وأرقام فقط');
      return;
    }
    final d = int.tryParse(days.text.trim()) ?? 0;
    try {
      await api.post('panel/api/clients/add', {
        'inboundIds': [inb],
        'client': {
          'email': name,
          'id': _uuid(),
          'subId': _rid(16),
          'flow': '',
          'enable': true,
          'totalGB': ((double.tryParse(gb.text.trim()) ?? 0) * 1073741824).round(),
          'expiryTime': d == 0
              ? 0
              : DateTime.now().add(Duration(days: d)).millisecondsSinceEpoch,
          'limitIp': int.tryParse(ips.text.trim()) ?? 0,
          'tgId': 0,
          'comment': '',
          'reset': 0,
          'resetDay': 0,
          'resetMax': 0,
          'resetWeekday': 0,
          'security': 'auto',
        },
      });
      await loadClients();
      if (mounted) _snack(context, 'تمت الإضافة');
    } catch (e) {
      if (mounted) _snack(context, _err(e));
    }
  }

  // ---- UI
  Widget errBox(String? e, VoidCallback retry) => e == null
      ? const SizedBox.shrink()
      : Card(
          color: const Color(0x33FF5252),
          child: ListTile(
              title: Text(e),
              trailing: IconButton(onPressed: retry, icon: const Icon(Icons.refresh))));

  Widget statCard(String t, String v, [String? sub]) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 4),
            Text(v, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            if (sub != null) Text(sub, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
        ),
      );

  Widget statusTab() {
    final s = status;
    if (s == null) {
      return ListView(padding: const EdgeInsets.all(12), children: [
        errBox(statusErr, loadStatus),
        if (statusErr == null) const Center(child: CircularProgressIndicator()),
      ]);
    }
    final mem = (s['mem'] as Map?) ?? {};
    final disk = (s['disk'] as Map?) ?? {};
    final xray = (s['xray'] as Map?) ?? {};
    final netIO = (s['netIO'] as Map?) ?? {};
    final netT = (s['netTraffic'] as Map?) ?? {};
    final memP = _n(mem['total']) == 0 ? 0 : _n(mem['current']) * 100 / _n(mem['total']);
    final diskP = _n(disk['total']) == 0 ? 0 : _n(disk['current']) * 100 / _n(disk['total']);
    final running = '${xray['state']}'.toLowerCase() == 'running';
    return RefreshIndicator(
      onRefresh: loadStatus,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        errBox(statusErr, loadStatus),
        Card(
          child: ListTile(
            leading: Icon(Icons.circle, color: running ? Colors.greenAccent : Colors.redAccent, size: 14),
            title: Text('Xray ${running ? 'شغّال' : '${xray['state'] ?? 'غير معروف'}'}'),
            subtitle: Text('${xray['version'] ?? ''}'),
            trailing: FilledButton.tonal(onPressed: restartXray, child: const Text('إعادة تشغيل')),
          ),
        ),
        Row(children: [
          Expanded(child: statCard('المعالج', '${_n(s['cpu']).toStringAsFixed(1)}%')),
          Expanded(child: statCard('الذاكرة', '${memP.toStringAsFixed(1)}%', '${_bytes(_n(mem['current']))} / ${_bytes(_n(mem['total']))}')),
        ]),
        Row(children: [
          Expanded(child: statCard('التخزين', '${diskP.toStringAsFixed(1)}%', '${_bytes(_n(disk['current']))} / ${_bytes(_n(disk['total']))}')),
          Expanded(child: statCard('مدة التشغيل', _uptime(_n(s['uptime'])))),
        ]),
        Row(children: [
          Expanded(child: statCard('السرعة الآن', '↑ ${_bytes(_n(netIO['up']))}/s', '↓ ${_bytes(_n(netIO['down']))}/s')),
          Expanded(child: statCard('الإجمالي', '↑ ${_bytes(_n(netT['sent']))}', '↓ ${_bytes(_n(netT['recv']))}')),
        ]),
        Row(children: [
          Expanded(child: statCard('اتصالات TCP', '${_n(s['tcpCount'])}')),
          Expanded(child: statCard('اتصالات UDP', '${_n(s['udpCount'])}')),
        ]),
        Row(children: [
          Expanded(child: statCard('العملاء المتصلون', '${onlines.length}')),
          Expanded(child: statCard('عدد العملاء', '${clients.length}')),
        ]),
      ]),
    );
  }

  Widget inboundsTab() {
    return RefreshIndicator(
      onRefresh: loadInbounds,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        errBox(inbErr, loadInbounds),
        if (inbErr == null && inbounds.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('ما كو واردات'))),
        ...inbounds.map((i) {
          final up = _n(i['up']), down = _n(i['down']), total = _n(i['total']);
          return Card(
            child: ListTile(
              leading: Icon(Icons.circle, size: 14, color: i['enable'] == false ? Colors.grey : Colors.greenAccent),
              title: Text('${i['remark'] == null || '${i['remark']}'.isEmpty ? 'وارد ${i['id']}' : i['remark']}'),
              subtitle: Text('${i['protocol']} : ${i['port']}\n↑ ${_bytes(up)}   ↓ ${_bytes(down)}${total > 0 ? '   /  ${_bytes(total)}' : ''}'),
              isThreeLine: true,
            ),
          );
        }),
      ]),
    );
  }

  Widget clientsTab() {
    final list = clients
        .where((c) => '${c['email']}'.toLowerCase().contains(filter.toLowerCase()))
        .toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: TextField(
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'بحث بالاسم',
              border: OutlineInputBorder()),
          onChanged: (v) => setState(() => filter = v),
        ),
      ),
      if (loadingCli) const LinearProgressIndicator(),
      Expanded(
        child: RefreshIndicator(
          onRefresh: loadClients,
          child: ListView(padding: const EdgeInsets.all(12), children: [
            errBox(cliErr, loadClients),
            if (cliErr == null && !loadingCli && list.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('ما كو عملاء'))),
            ...list.map((c) {
              final email = '${c['email']}';
              final tr = (c['traffic'] as Map?) ?? {};
              final used = _n(tr['up']) + _n(tr['down']);
              final total = _n(c['totalGB']);
              final en = c['enable'] != false;
              final on = onlines.contains(email);
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.circle, size: 12, color: on ? Colors.greenAccent : Colors.grey),
                      const SizedBox(width: 8),
                      Expanded(child: Text(email, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                      Switch(value: en, onChanged: (v) => toggle(email, v)),
                    ]),
                    Text('الاستهلاك: ${_bytes(used)}${total > 0 ? ' / ${_bytes(total)}' : ' / بلا حد'}'),
                    if (total > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: LinearProgressIndicator(value: (used / total).clamp(0, 1).toDouble()),
                      ),
                    Text('الانتهاء: ${_expiry(_n(c['expiryTime']))}'),
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      FilledButton(onPressed: () => showLinks(email), child: const Text('الرابط / QR')),
                      OutlinedButton(onPressed: () => editLimits(c), child: const Text('الحدود')),
                      OutlinedButton(onPressed: () => resetTraffic(email), child: const Text('تصفير')),
                      FilledButton.tonal(
                          style: FilledButton.styleFrom(foregroundColor: Colors.redAccent),
                          onPressed: () => delClient(email),
                          child: const Text('حذف')),
                    ]),
                  ]),
                ),
              );
            }),
          ]),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.panel['name']}'),
        actions: [
          IconButton(
              tooltip: 'اللوحة الأصلية',
              onPressed: widget.openWeb,
              icon: const Icon(Icons.open_in_browser)),
        ],
        bottom: TabBar(controller: tabs, tabs: const [
          Tab(text: 'الحالة'),
          Tab(text: 'الواردات'),
          Tab(text: 'العملاء'),
        ]),
      ),
      floatingActionButton: AnimatedBuilder(
        animation: tabs,
        builder: (_, __) => tabs.index == 2
            ? FloatingActionButton.extended(
                onPressed: addClient,
                icon: const Icon(Icons.person_add),
                label: const Text('عميل جديد'))
            : const SizedBox.shrink(),
      ),
      body: SafeArea(
        child: TabBarView(controller: tabs, children: [
          statusTab(),
          inboundsTab(),
          clientsTab(),
        ]),
      ),
    );
  }
}
