import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'smart_client_core.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // تشغيل الواجهة فوراً في اللحظة الأولى لمنع الشاشة البيضاء نهائياً
  runApp(const LvnoUnifiedWalletApp());
}

class LvnoUnifiedWalletApp extends StatelessWidget {
  const LvnoUnifiedWalletApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'محفظة نت سباي',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B1120),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF10B981),
          secondary: Color(0xFF3B82F6),
        ),
      ),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: SafeBootScreen(),
      ),
    );
  }
}

class SafeBootScreen extends StatefulWidget {
  const SafeBootScreen({super.key});

  @override
  State<SafeBootScreen> createState() => _SafeBootScreenState();
}

class _SafeBootScreenState extends State<SafeBootScreen> {
  bool _isReady = false;
  String? _errorMsg;

  // سيقوم سكربت البناء باستبدال هذه القيم تلقائياً من ملف google-services.json
  static const String _injectedApiKey = "INJECT_API_KEY";
  static const String _injectedAppId = "INJECT_APP_ID";
  static const String _injectedSenderId = "INJECT_SENDER_ID";
  static const String _injectedProjectId = "netspay-1f0fc";

  @override
  void initState() {
    super.initState();
    _initCloud();
  }

  Future<void> _initCloud() async {
    try {
      if (Firebase.apps.isEmpty) {
        if (_injectedApiKey.isNotEmpty && !_injectedApiKey.startsWith("INJECT_")) {
          await Firebase.initializeApp(
            options: const FirebaseOptions(
              apiKey: _injectedApiKey,
              appId: _injectedAppId,
              messagingSenderId: _injectedSenderId,
              projectId: _injectedProjectId,
            ),
          ).timeout(const Duration(seconds: 12));
        } else {
          await Firebase.initializeApp().timeout(const Duration(seconds: 12));
        }
      }

      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously().timeout(const Duration(seconds: 12));
      }

      if (mounted) {
        setState(() => _isReady = true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMsg = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMsg != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off_rounded, color: Colors.amber, size: 56),
                const SizedBox(height: 16),
                const Text(
                  "تعذر الاتصال الأولي بالسحابة",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Text(
                  _errorMsg!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () {
                    setState(() => _errorMsg = null);
                    _initCloud();
                  },
                  child: const Text("إعادة المحاولة"),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_isReady) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF10B981)),
              SizedBox(height: 16),
              Text("جاري فتح محفظة نت سباي...", style: TextStyle(fontSize: 15)),
            ],
          ),
        ),
      );
    }

    return const WalletDashboardScreen();
  }
}

class WalletDashboardScreen extends StatefulWidget {
  const WalletDashboardScreen({super.key});

  @override
  State<WalletDashboardScreen> createState() => _WalletDashboardScreenState();
}

class _WalletDashboardScreenState extends State<WalletDashboardScreen> {
  String activeWalletId = "consumer_01";
  String activeHostId = "host_alhuda_01";

  late SmartClientEngine _engine;
  final TextEditingController _receiverCtrl = TextEditingController();
  final TextEditingController _amountCtrl = TextEditingController(text: "1000");
  String _statusMessage = "";

  @override
  void initState() {
    super.initState();
    _engine = SmartClientEngine(walletId: activeWalletId, currentHostId: activeHostId);
    _engine.initializeEngine();
  }

  void _switchDemoProfile(String newWalletId) {
    setState(() {
      activeWalletId = newWalletId;
      _engine.walletId = newWalletId;
      _statusMessage = "تم التبديل إلى حساب: $newWalletId";
    });
  }

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: const Text('محفظة نت سباي الموحدة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.switch_account, color: Color(0xFF10B981)),
            onSelected: _switchDemoProfile,
            itemBuilder: (context) => const [
              PopupMenuItem(value: "consumer_01", child: Text("تجربة كمستفيد (consumer_01)")),
              PopupMenuItem(value: "agent_01", child: Text("تجربة كبقال (agent_01)")),
              PopupMenuItem(value: "dist_01", child: Text("تجربة كموزع (dist_01)")),
            ],
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: db.collection('wallets').doc(activeWalletId).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text("خطأ في قراءة المحفظة: ${snapshot.error}"));
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: Text(
                  "جاري تحميل بيانات المحفظة... تأكد من الضغط على زر (Bootstrap) في لوحة الأدمن",
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final wallet = snapshot.data!.data() as Map<String, dynamic>;
          final String role = (wallet['role'] ?? 'consumer').toString();
          final int balance = ((wallet['balance_yer'] ?? 0) as num).toInt();
          final int dailyUsed = ((wallet['daily_transferred_today'] ?? 0) as num).toInt();

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildBalanceCard(wallet['display_name'] ?? activeWalletId, role, balance, dailyUsed),
                const SizedBox(height: 16),
                if (_statusMessage.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF064E3B),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(_statusMessage, style: const TextStyle(fontSize: 13)),
                  ),
                _buildSmartInternetToggleCard(),
                const SizedBox(height: 16),
                if (role == 'host' || activeWalletId == 'dist_01') _buildHostMeterCard(db),
                _buildTransferCard(role),
                const SizedBox(height: 16),
                _buildStaticQrCard(activeWalletId),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBalanceCard(String name, String role, int balance, int dailyUsed) {
    final roleNames = {
      'consumer': 'حساب مستفيد',
      'agent': 'نقطة بيع معتمدة (عمولة 10%)',
      'distributor': 'موزع جملة معتمد',
      'host': 'شريك صاحب شبكة',
    };

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF065F46), Color(0xFF0F172A)],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(20)),
                child: Text(roleNames[role] ?? role, style: const TextStyle(fontSize: 11, color: Color(0xFF6EE7B7))),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text("الرصيد المتاح", style: TextStyle(fontSize: 12, color: Colors.white70)),
          Text("$balance ريال", style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.white)),
          const SizedBox(height: 8),
          Text("المعرف: $activeWalletId | المسحوب اليوم: $dailyUsed ريال", style: const TextStyle(fontSize: 11, color: Colors.white60)),
        ],
      ),
    );
  }

  Widget _buildSmartInternetToggleCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("اتصال الشبكة الموحد", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  Text(
                    _engine.isVpnActive ? "متصل الآن عبر النفق الذكي" : "الاتصال متوقف",
                    style: TextStyle(fontSize: 12, color: _engine.isVpnActive ? const Color(0xFF10B981) : Colors.grey),
                  ),
                ],
              ),
              Switch(
                value: _engine.isVpnActive,
                activeColor: const Color(0xFF10B981),
                onChanged: (val) async {
                  if (val) {
                    await _engine.startSmartConnection();
                  } else {
                    await _engine.stopSmartConnection();
                  }
                  setState(() {});
                },
              ),
            ],
          ),
          const Divider(color: Colors.white12, height: 20),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.bolt, size: 18, color: Colors.amber),
              label: const Text("اختبار إرسال نبضة استهلاك فورية للوحة القيادة", style: TextStyle(fontSize: 12)),
              onPressed: () async {
                await _engine.sendUsageHeartbeatDirect(
                  extraWanBytes: 800 * 1024 * 1024,
                  extraCacheBytes: 200 * 1024 * 1024,
                );
                setState(() {
                  _statusMessage = "تم إرسال نبضة استهلاك (1000 MB) وتحديث لوحة القيادة لحظياً!";
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHostMeterCard(FirebaseFirestore db) {
    return StreamBuilder<DocumentSnapshot>(
      stream: db.collection('hosts').doc(activeHostId).snapshots(),
      builder: (context, snap) {
        if (!snap.hasData || !snap.data!.exists) return const SizedBox.shrink();
        final h = snap.data!.data() as Map<String, dynamic>;
        final num wanMb = (h['current_month_wan_mb'] ?? 0) as num;
        final int dueYer = ((h['amount_due_yer'] ?? 0) as num).toInt();

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF172554),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.blueAccent.withOpacity(0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("📡 عداد استهلاك خطك (WAN) والمستحقات", style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text("إجمالي العبور من سلك الإنترنت: ${wanMb.toStringAsFixed(0)} MB"),
              Text("المستحقات الجاهزة للتسييل: $dueYer ريال", style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: dueYer >= 1000
                    ? () async {
                        await _engine.claimHostWanEarnings(dueYer);
                        setState(() => _statusMessage = "تم سحب $dueYer ريال إلى محفظتك بنجاح!");
                      }
                    : null,
                child: const Text("سحب المستحقات إلى المحفظة (لبيعها للبقالات)"),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTransferCard(String role) {
    final bool isAgent = role == 'agent';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            isAgent ? "⚡ شحن فوري لزبون (تربح عمولة 10% تلقائياً)" : "💸 تحويل رصيد لمحفظة أخرى",
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _receiverCtrl,
            decoration: const InputDecoration(
              labelText: "معرف محفظة المستلم (مثال: consumer_01)",
              filled: true,
              fillColor: Color(0xFF0F172A),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _amountCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: "المبلغ بالريال اليمني",
              filled: true,
              fillColor: Color(0xFF0F172A),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: () async {
              try {
                final amt = int.tryParse(_amountCtrl.text.trim()) ?? 0;
                final res = await _engine.executeTransferDirect(
                  receiverId: _receiverCtrl.text.trim(),
                  amountYer: amt,
                );
                setState(() {
                  _statusMessage = "✅ تم التحويل! المخصوم الصافي: ${res['net_deducted_yer']} ريال (العمولة: ${res['agent_commission_yer']} ريال)";
                });
              } catch (e) {
                setState(() => _statusMessage = "❌ خطأ: ${e.toString()}");
              }
            },
            child: const Text("تنفيذ العملية الفورية", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildStaticQrCard(String walletId) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          const Text("الكود الثابت لاستلام الرصيد (Static QR)", style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: QrImageView(data: walletId, version: QrVersions.auto, size: 150.0),
          ),
          const SizedBox(height: 8),
          Text(walletId, style: const TextStyle(fontFamily: 'monospace', color: Colors.white70)),
        ],
      ),
    );
  }
}
