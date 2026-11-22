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
  return d > 0 ? '${d}d ${h}h' : '${h}h ${m}m';
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
// Log in to 3X-UI (form first, then JSON) and return the session cookies.
Future<List<Cookie>> xLogin(String base, String user, String pass) async {
  var last = '';
  for (final asJson in [false, true]) {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 12);
    c.badCertificateCallback = (cert, host, port) => true;
    try {
      final req = await c.postUrl(Uri.parse('${base}login'));
      req.followRedirects = false;
      if (asJson) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode({'username': user, 'password': pass})));
      } else {
        req.headers.contentType =
            ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
        req.add(utf8.encode(
            'username=${Uri.encodeQueryComponent(user)}&password=${Uri.encodeQueryComponent(pass)}'));
      }
      final res = await req.close().timeout(const Duration(seconds: 30));
      final txt = await utf8.decodeStream(res);
      if (RegExp(r'"success"\s*:\s*true').hasMatch(txt)) return res.cookies;
      last = 'HTTP ${res.statusCode}: ${txt.length > 120 ? txt.substring(0, 120) : txt}';
    } catch (e) {
      last = '$e';
    } finally {
      c.close(force: true);
    }
  }
  throw Exception('فشل الدخول للوحة ($last)');
}

class _AuthFail implements Exception {
  final String msg;
  _AuthFail(this.msg);
  @override
  String toString() => msg;
}

class XApi {
  final String base; // ends with '/'
  final String token;
  final String user;
  final String pass;
  String _cookie = '';
  XApi(this.base, this.token, {this.user = '', this.pass = ''});

  // no API token -> log in with username/password and use the session cookie
  bool get _useLogin => token.isEmpty && user.isNotEmpty;

  Future<void> _login() async {
    final ck = await xLogin(base, user, pass);
    _cookie = ck.map((k) => '${k.name}=${k.value}').join('; ');
  }

  Future<Map<String, dynamic>> _req(String method, String path,
      {Object? body}) async {
    if (_useLogin && _cookie.isEmpty) await _login();
    try {
      return await _do(method, path, body);
    } on _AuthFail catch (e) {
      if (!_useLogin) throw Exception(e.msg);
      await _login();
      try {
        return await _do(method, path, body);
      } on _AuthFail catch (e2) {
        throw Exception(e2.msg);
      }
    }
  }

  Future<Map<String, dynamic>> _do(String method, String path, Object? body) async {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 12);
    c.badCertificateCallback = (cert, host, port) => true;
    try {
      final req = await c.openUrl(method, Uri.parse('$base$path'));
      req.followRedirects = false;
      if (_useLogin) {
        req.headers.set('Cookie', _cookie);
      } else {
        req.headers.set('Authorization', 'Bearer $token');
      }
      req.headers.set('Accept', 'application/json');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(const Duration(seconds: 30));
      final txt = await utf8.decodeStream(res);
      if (res.statusCode >= 300 && res.statusCode < 400) {
        throw _AuthFail(_useLogin
            ? 'اللوحة رفضت جلسة الدخول، تأكد من اليوزر والباسورد'
            : 'اللوحة رفضت التوكن وحوّلتني لصفحة الدخول. أنشئ توكن جديد بصلاحية «مسؤول» والصقه من جديد');
      }
      if (res.statusCode == 401 ||
          res.statusCode == 403 ||
          res.statusCode == 404) {
        throw _AuthFail(
            'تعذر الوصول (${res.statusCode}): تأكد من بيانات الدخول ومن رابط اللوحة');
      }
      dynamic j;
      try {
        j = jsonDecode(txt);
      } catch (_) {
        final looksHtml = txt.trimLeft().toLowerCase().startsWith('<');
        throw Exception(looksHtml
            ? 'اللوحة رجّعت صفحة ويب بدل بيانات: بيانات الدخول غير مقبولة أو الرابط ناقصه المسار العشوائي'
            : 'رد غير متوقع من اللوحة (HTTP ${res.statusCode})');
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

// ------------------------------------------------------------ quick inbound presets
// اسم البرنامج بالعربي -> الدومين اللي يُستخدم كـ Host/SNI.
// عدّل أو زِد على هذي القائمة حسب اللي يشتغل عندك.
class AppPreset {
  final String name;
  final List<String> aliases;
  final String host; // serverName (SNI)
  final String? target; // dest لـ Reality، الافتراضي host:443
  const AppPreset(this.name, this.aliases, this.host, [this.target]);
  String get dest => target ?? '$host:443';
}

const kPresets = <AppPreset>[
  // بث
  AppPreset('تيك توك', ['tiktok', 'تيكتوك', 'تك توك'], 'www.tiktok.com'),
  AppPreset('يوتيوب', ['youtube', 'يوتوب'], 'www.youtube.com'),
  AppPreset('OSN+', ['osn', 'اوسن', 'او اس ان'], 'www.osnplus.com'),
  AppPreset('شاهد', ['shahid', 'mbc', 'شاهد نت'], 'shahid.mbc.net'),
  // تواصل وترفيه
  AppPreset('سناب شات', ['snapchat', 'سناب', 'سناب چات'], 'www.snapchat.com'),
  AppPreset('واتساب', ['whatsapp', 'واتس', 'وتساب'], 'web.whatsapp.com'),
  AppPreset('انستغرام', ['instagram', 'انستا', 'انستجرام'], 'www.instagram.com'),
  AppPreset('تلكرام', ['telegram', 'تيليجرام', 'تلغرام', 'تيليغرام'], 'telegram.org', 'core.telegram.org:443'),
  AppPreset('EA Sports', ['ea', 'اي ايه', 'ea sports'], 'www.ea.com'),
  AppPreset('تويتر', ['twitter', 'اكس', 'x'], 'x.com'),
  AppPreset('ويز', ['waze'], 'www.waze.com'),
  AppPreset('بلي', ['bly'], ''), // الدومين غير معروف: اكتبه هنا
  AppPreset('فيسبوك', ['facebook', 'فيس بوك', 'فيس', 'ماسنجر'], 'www.facebook.com'),
  AppPreset('سبوتيفاي', ['spotify', 'سبوتفاي'], 'open.spotify.com'),
  AppPreset('تعليم', ['education'], ''), // الدومين غير معروف: اكتبه هنا
  AppPreset('انغامي', ['anghami', 'أنغامي'], 'www.anghami.com'),
  AppPreset('ببجي', ['pubg', 'بوبجي'], 'www.pubgmobile.com'),
  AppPreset('فايبر', ['viber', 'فايبير'], 'www.viber.com'),
  AppPreset('Busuu', ['busuu', 'بوسو'], 'www.busuu.com'),
];

String _norm(String s) {
  var t = s.toLowerCase().trim();
  t = t.replaceAll(RegExp('[\u064B-\u065F\u0670\u0640]'), '');
  t = t
      .replaceAll(RegExp('[أإآ]'), 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .replaceAll('ؤ', 'و')
      .replaceAll('ئ', 'ي');
  return t.replaceAll(RegExp(r'\s+'), '');
}

AppPreset? findPreset(String q) {
  final n = _norm(q);
  if (n.isEmpty) return null;
  for (final p in kPresets) {
    for (final a in [p.name, ...p.aliases]) {
      if (_norm(a) == n) return p;
    }
  }
  if (n.length < 2) return null;
  for (final p in kPresets) {
    for (final a in [p.name, ...p.aliases]) {
      final an = _norm(a);
      if (an.length >= 2 && (n.contains(an) || an.contains(n))) return p;
    }
  }
  return null;
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
    api = XApi(b, '${widget.panel['token'] ?? ''}',
        user: '${widget.panel['user'] ?? ''}',
        pass: '${widget.panel['pass'] ?? ''}');
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

  // ---- quick inbound: الاسم + اسم البرنامج بالعربي فقط، والباقي تلقائي
  int _freePort(Set<int> used) {
    for (var i = 0; i < 1000; i++) {
      final p = 20000 + _rng.nextInt(40000);
      if (!used.contains(p)) return p;
    }
    throw Exception('ما لقيت بورت فارغ');
  }

  Future<Map> _tryBoth(String path) async {
    try {
      final m = await api.get(path);
      if (m['obj'] is Map) return m['obj'] as Map;
    } catch (_) {}
    final m = await api.post(path);
    return (m['obj'] as Map?) ?? {};
  }

  String _hex(int n) => List.generate(n, (_) => _rng.nextInt(16).toRadixString(16)).join();

  Future<void> quickInbound() async {
    final name = TextEditingController();
    final app = TextEditingController();
    bool withClient = true;
    final ok = await showDialog<bool>(
        context: context,
        builder: (x) => StatefulBuilder(
              builder: (x, setS) {
                final pr = findPreset(app.text);
                return AlertDialog(
                  title: const Text('إدخال سريع'),
                  content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: name,
                          decoration: const InputDecoration(labelText: 'الاسم')),
                      TextField(
                          controller: app,
                          onChanged: (_) => setS(() {}),
                          decoration: const InputDecoration(
                              labelText: 'اسم البرنامج بالعربي (مثل: واتساب)')),
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                            app.text.trim().isEmpty
                                ? ''
                                : pr == null
                                    ? 'برنامج غير معروف'
                                    : pr.host.isEmpty
                                    ? '⚠ ${pr.name}: الدومين غير مضاف بالكود'
                                    : '✓ ${pr.name}  →  ${pr.dest}',
                            textDirection: TextDirection.ltr,
                            style: TextStyle(
                                color: pr == null || pr.host.isEmpty ? Colors.redAccent : Colors.greenAccent)),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                          spacing: 6,
                          runSpacing: 0,
                          children: kPresets
                              .map((p) => ActionChip(
                                  label: Text(p.name),
                                  onPressed: () => setS(() => app.text = p.name)))
                              .toList()),
                      CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: withClient,
                          onChanged: (v) => setS(() => withClient = v ?? true),
                          title: const Text('إنشاء عميل وعرض الرابط تلقائياً')),
                    ]),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(x, false),
                        child: const Text('إلغاء')),
                    TextButton(
                        onPressed: () => Navigator.pop(x, true),
                        child: const Text('إنشاء')),
                  ],
                );
              },
            ));
    if (ok != true) return;
    final preset = findPreset(app.text);
    if (preset == null) {
      _snack(context, 'ما عرفت البرنامج، اختار من القائمة');
      return;
    }
    if (preset.host.isEmpty) {
      _snack(context, 'أضف دومين ${preset.name} بالقائمة kPresets أولاً');
      return;
    }
    final label = name.text.trim().isEmpty ? preset.name : name.text.trim();
    final remark = '$label - ${preset.name}';
    try {
      await loadInbounds();
      final used = <int>{22, 80, 443};
      for (final i in inbounds) {
        used.add(_n(i['port']).toInt());
      }
      final pu = Uri.tryParse('${widget.panel['url']}');
      if (pu != null && pu.hasPort) used.add(pu.port);

      // مفاتيح Reality جديدة لكل وارد
      final kp = await _tryBoth('panel/api/server/getNewX25519Cert');
      final priv = '${kp['privateKey'] ?? ''}';
      final pub = '${kp['publicKey'] ?? ''}';
      if (priv.isEmpty || pub.isEmpty) throw Exception('فشل توليد مفاتيح Reality');
      // تشفير VLESS (mlkem768x25519plus) ، إذا ما توفر نكمل بدون
      var dec = 'none', enc = 'none';
      try {
        final ve = await _tryBoth('panel/api/server/getNewVlessEnc');
        final auths = (ve['auths'] as List?) ?? [];
        Map? pick;
        for (final a in auths) {
          if (a is Map && '${a['label']}'.contains('X25519')) {
            pick ??= a;
          }
        }
        pick ??= auths.isNotEmpty && auths.first is Map ? auths.first as Map : null;
        if (pick != null &&
            '${pick['decryption']}'.isNotEmpty &&
            '${pick['encryption']}'.isNotEmpty) {
          dec = '${pick['decryption']}';
          enc = '${pick['encryption']}';
        }
      } catch (_) {}
      final shortIds = [12, 6, 14, 10, 2, 4, 8, 16].map(_hex).toList();
      final spider = '/${_rid(16)}';

      dynamic id;
      int port = 0;
      Object? lastErr;
      for (var attempt = 0; attempt < 4; attempt++) {
        port = _freePort(used);
        used.add(port);
        try {
          final m = await api.post('panel/api/inbounds/add', {
            'up': 0,
            'down': 0,
            'total': 0,
            'remark': remark,
            'enable': true,
            'expiryTime': 0,
            'listen': '',
            'port': port,
            'protocol': 'vless',
            'tag': 'in-$port-tcp',
            'settings': jsonEncode({
              'clients': [],
              'decryption': dec,
              'encryption': enc,
              'testseed': [900, 500, 900, 256],
            }),
            'streamSettings': jsonEncode({
              'network': 'tcp',
              'tcpSettings': {
                'acceptProxyProtocol': false,
                'header': {'type': 'none'},
              },
              'security': 'reality',
              'realitySettings': {
                'show': false,
                'xver': 0,
                'target': preset.dest,
                'serverNames': [preset.host],
                'privateKey': priv,
                'minClientVer': '',
                'maxClientVer': '',
                'maxTimediff': 0,
                'shortIds': shortIds,
                'mldsa65Seed': '',
                'settings': {
                  'publicKey': pub,
                  'fingerprint': 'chrome',
                  'serverName': '',
                  'spiderX': spider,
                  'mldsa65Verify': '',
                },
              },
            }),
            'sniffing': jsonEncode({
              'enabled': true,
              'destOverride': ['http', 'tls', 'quic', 'fakedns'],
              'metadataOnly': false,
              'routeOnly': false,
            }),
          });
          final o = m['obj'];
          id = o is Map ? o['id'] : null;
          lastErr = null;
          break;
        } catch (e) {
          lastErr = e;
        }
      }
      if (lastErr != null) throw lastErr;
      await loadInbounds();
      if (id == null) {
        for (final i in inbounds) {
          if (_n(i['port']).toInt() == port) id = i['id'];
        }
      }
      if (!mounted) return;
      _snack(context, 'تم إنشاء الوارد على البورت $port');
      if (withClient && id != null) {
        final email = 'u${_rid(8)}';
        await api.post('panel/api/clients/add', {
          'inboundIds': [id],
          'client': {
            'email': email,
            'id': _uuid(),
            'subId': _rid(16),
            'flow': 'xtls-rprx-vision',
            'enable': true,
            'totalGB': 0,
            'expiryTime': 0,
            'limitIp': 0,
            'tgId': 0,
            'comment': label,
            'reset': 0,
            'resetDay': 0,
            'resetMax': 0,
            'resetWeekday': 0,
            'security': 'auto',
          },
        });
        await loadClients();
        if (mounted) await showLinks(email);
      }
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
            Text(v,
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            if (sub != null)
              Text(sub,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: statCard('المعالج', '${_n(s['cpu']).toStringAsFixed(1)}%')),
          Expanded(child: statCard('الذاكرة', '${memP.toStringAsFixed(1)}%', '${_bytes(_n(mem['current']))} / ${_bytes(_n(mem['total']))}')),
          ]),
        ),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: statCard('التخزين', '${diskP.toStringAsFixed(1)}%', '${_bytes(_n(disk['current']))} / ${_bytes(_n(disk['total']))}')),
          Expanded(child: statCard('مدة التشغيل', _uptime(_n(s['uptime'])))),
          ]),
        ),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: statCard('السرعة الآن', '↑ ${_bytes(_n(netIO['up']))}/s', '↓ ${_bytes(_n(netIO['down']))}/s')),
          Expanded(child: statCard('الإجمالي', '↑ ${_bytes(_n(netT['sent']))}', '↓ ${_bytes(_n(netT['recv']))}')),
          ]),
        ),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: statCard('اتصالات TCP', '${_n(s['tcpCount'])}')),
          Expanded(child: statCard('اتصالات UDP', '${_n(s['udpCount'])}')),
          ]),
        ),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: statCard('العملاء المتصلون', '${onlines.length}')),
          Expanded(child: statCard('عدد العملاء', '${clients.length}')),
          ]),
        ),
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
            : tabs.index == 1
                ? FloatingActionButton.extended(
                    onPressed: quickInbound,
                    icon: const Icon(Icons.bolt),
                    label: const Text('إدخال سريع'))
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
