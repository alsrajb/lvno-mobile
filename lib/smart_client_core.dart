import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class DnsEntry {
  final String ip;
  final int expiresAt;
  DnsEntry(this.ip, this.expiresAt);
}

class SmartClientEngine {
  static const MethodChannel _vpnChannel = MethodChannel('com.lvno.smartclient/vpn');
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String walletId;
  String currentHostId;

  // إعدادات التكتيك الحية المستلمة من السحابة
  Map<String, dynamic> liveBlueprint = {};
  bool isVpnActive = false;
  bool isNasReachable = false;
  Timer? _heartbeatTimer;

  // ذاكرة الـ DNS المحلية (L1 RAM: 30,000 نطاق)
  final int _maxRamDomains = 30000;
  final LinkedHashMap<String, DnsEntry> _l1RamDns = LinkedHashMap();
  final Set<String> _blockedDomains = {};
  final Map<String, String> _newDnsDiscoveries = {};

  SmartClientEngine({required this.walletId, required this.currentHostId});

  String get _nasBaseUrl =>
      liveBlueprint['network_bus']?['nas_ip'] != null
          ? "http://${liveBlueprint['network_bus']['nas_ip']}"
          : "http://10.99.99.10";

  /// 1. تهيئة المحرك والاستماع لوثيقة التكتيك الحي (Zero-Update Cloud Blueprint)
  Future<void> initializeEngine() async {
    _db.doc('system_control/live_tactical_blueprint').snapshots().listen((snap) {
      if (snap.exists && snap.data() != null) {
        liveBlueprint = snap.data()!;
      }
    });

    await _preloadNeighborhoodDnsFromNas();
  }

  /// 2. شحن ذاكرة الـ DNS من الخازن الشبكي 10.99.99.10 خلال 350ms
  Future<void> _preloadNeighborhoodDnsFromNas() async {
    try {
      final res = await http
          .get(Uri.parse("$_nasBaseUrl/dns_shared/neighborhood_dns_pack.json"))
          .timeout(const Duration(milliseconds: 350));

      if (res.statusCode == 200) {
        isNasReachable = true;
        final map = jsonDecode(res.body);
        int exp = DateTime.now().millisecondsSinceEpoch + 3600000;
        (map['records'] as Map<String, dynamic>?)?.forEach((k, v) {
          _putDnsInRam(k, v.toString(), exp);
        });
        (map['blocked'] as List<dynamic>?)?.forEach((d) {
          _blockedDomains.add(d.toString());
        });
      }
    } catch (_) {
      isNasReachable = false;
    }
  }

  void _putDnsInRam(String domain, String ip, int exp) {
    if (_l1RamDns.length >= _maxRamDomains) {
      _l1RamDns.remove(_l1RamDns.keys.first);
    }
    _l1RamDns[domain] = DnsEntry(ip, exp);
  }

  /// 3. تشغيل النفق الذكي وبدء نبضة المحاسبة كل دقيقتين
  Future<bool> startSmartConnection() async {
    final bool started = await _vpnChannel.invokeMethod('startVpn') ?? false;
    if (started) {
      isVpnActive = true;
      await _preloadNeighborhoodDnsFromNas();
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(minutes: 2), (_) {
        sendUsageHeartbeatDirect();
      });
    }
    return started;
  }

  Future<void> stopSmartConnection() async {
    _heartbeatTimer?.cancel();
    await _vpnChannel.invokeMethod('stopVpn');
    isVpnActive = false;
  }

  /// 4. جلب تاريخ اليوم بتوقيت اليمن (UTC+3) لتصفير السقف اليومي تلقائياً
  String _getCurrentDateYemen() {
    final yemenNow = DateTime.now().toUtc().add(const Duration(hours: 3));
    return yemenNow.toIso8601String().substring(0, 10);
  }

  /// 5. إرسال نبضة الاستهلاك وعزل الكاش السري مباشرة إلى Firestore
  Future<void> sendUsageHeartbeatDirect({int extraWanBytes = 0, int extraCacheBytes = 0}) async {
    final Map<dynamic, dynamic>? nativeCounters =
        await _vpnChannel.invokeMethod('collectTelemetry');

    final int wanBytesDelta = ((nativeCounters?['wanBytesDelta'] ?? 0) as int) + extraWanBytes;
    final int secretCacheBytesDelta =
        ((nativeCounters?['secretCacheBytesDelta'] ?? 0) as int) + extraCacheBytes;

    if (wanBytesDelta <= 0 && secretCacheBytesDelta <= 0) return;

    final double wanMB = wanBytesDelta / (1024 * 1024);
    final double cacheMB = secretCacheBytesDelta / (1024 * 1024);

    final pricing = liveBlueprint['pricing_rules'] ?? {};
    final double consumerRateMb = ((pricing['consumer_price_per_gb'] ?? 210) as num) / 1024.0;
    final double hostWanRateMb = ((pricing['host_wan_price_per_gb'] ?? 200) as num) / 1024.0;
    final double agentCommRatio = ((pricing['agent_commission_ratio'] ?? 0.10) as num).toDouble();

    final int consumerChargeYer = ((wanMB + cacheMB) * consumerRateMb).ceil();
    final int hostPayoutYer = (wanMB * hostWanRateMb).floor();
    final int agentCommissionEst = (consumerChargeYer * agentCommRatio).floor();
    final int secretSystemProfitYer = consumerChargeYer - hostPayoutYer - agentCommissionEst;

    final String yearMonth = _getCurrentDateYemen().substring(0, 7);

    final walletRef = _db.collection('wallets').doc(walletId);
    final hostRef = _db.collection('hosts').doc(currentHostId);
    final secretRef = _db.collection('admin_secret_metrics').doc('${currentHostId}_$yearMonth');

    await _db.runTransaction((t) async {
      final walletSnap = await t.get(walletRef);
      if (!walletSnap.exists) {
        await stopSmartConnection();
        return;
      }

      final wData = walletSnap.data()!;
      final int currentBalance = (wData['balance_yer'] ?? 0) as int;
      final bool killSwitch = wData['parental_controls']?['kill_switch_blocked'] == true;

      if (killSwitch || currentBalance < consumerChargeYer) {
        await stopSmartConnection();
        return;
      }

      // أ. خصم الاستهلاك الإجمالي من محفظة المستفيد
      t.update(walletRef, {
        'balance_yer': FieldValue.increment(-consumerChargeYer),
        'active_lease_expires_at': DateTime.now().millisecondsSinceEpoch + (5 * 60 * 1000),
        'updated_at': FieldValue.serverTimestamp(),
      });

      // ب. تحديث عداد صاحب الشبكة (يسجل حصراً ما عبر من سلك الـ WAN)
      t.set(hostRef, {
        'host_id': currentHostId,
        'current_month_wan_mb': FieldValue.increment(wanMB),
        'amount_due_yer': FieldValue.increment(hostPayoutYer),
        'last_heartbeat': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // ج. تحديث السجل السري للمنظومة (يظهر في شاشة كمبيوتر المدير فقط)
      t.set(secretRef, {
        'host_id': currentHostId,
        'month': yearMonth,
        'total_wan_mb': FieldValue.increment(wanMB),
        'total_secret_cache_mb': FieldValue.increment(cacheMB),
        'gross_consumer_sales_yer': FieldValue.increment(consumerChargeYer),
        'host_wan_payout_yer': FieldValue.increment(hostPayoutYer),
        'agents_10pct_cut_yer': FieldValue.increment(agentCommissionEst),
        'net_system_profit_yer': FieldValue.increment(secretSystemProfitYer),
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }

  /// 6. تنفيذ الحوالات والشحن الفوري مع فحص السقف اليومي وعمولة البقال 10%
  Future<Map<String, dynamic>> executeTransferDirect({
    required String receiverId,
    required int amountYer,
  }) async {
    if (receiverId.trim().isEmpty || receiverId == walletId) {
      throw Exception("معرف المستلم غير صالح");
    }
    if (amountYer < 100) {
      throw Exception("الحد الأدنى للتحويل 100 ريال");
    }

    const roleLimits = {
      'consumer': {'single': 5000, 'daily': 10000},
      'agent': {'single': 50000, 'daily': 300000},
      'distributor': {'single': 500000, 'daily': 2000000},
      'host': {'single': 500000, 'daily': 1000000},
    };

    final String today = _getCurrentDateYemen();
    final String txId = "tx_${walletId}_${DateTime.now().millisecondsSinceEpoch}";

    final senderRef = _db.collection('wallets').doc(walletId);
    final receiverRef = _db.collection('wallets').doc(receiverId.trim());
    final txRef = _db.collection('transactions').doc(txId);

    return await _db.runTransaction((t) async {
      final sSnap = await t.get(senderRef);
      final rSnap = await t.get(receiverRef);

      if (!sSnap.exists || !rSnap.exists) {
        throw Exception("أحد الحسابات غير موجود في المنظومة");
      }

      final sData = sSnap.data()!;
      final rData = rSnap.data()!;
      final String sRole = (sData['role'] ?? 'consumer').toString();
      final String rRole = (rData['role'] ?? 'consumer').toString();

      final limits = roleLimits[sRole] ?? roleLimits['consumer']!;
      if (amountYer > limits['single']!) {
        throw Exception("المبلغ يتجاوز سقف العملية الواحدة (${limits['single']} ريال)");
      }

      // التصفير الذكي للسقف اليومي إذا دخل يوم جديد
      final int usedToday =
          (sData['last_transfer_date'] == today) ? ((sData['daily_transferred_today'] ?? 0) as int) : 0;

      if (usedToday + amountYer > limits['daily']!) {
        throw Exception("تجاوزت السقف اليومي المسموح به (${limits['daily']} ريال)");
      }

      // احتساب عمولة البقال 10% آلياً عند شحن المستفيد
      int commission = 0;
      int netDeduct = amountYer;
      if (sRole == 'agent' && rRole == 'consumer') {
        commission = (amountYer * 0.10).floor();
        netDeduct = amountYer - commission;
      }

      final int currentBal = (sData['balance_yer'] ?? 0) as int;
      if (currentBal < netDeduct) {
        throw Exception("الرصيد غير كافٍ لإتمام العملية");
      }

      t.update(senderRef, {
        'balance_yer': FieldValue.increment(-netDeduct),
        'daily_transferred_today': usedToday + amountYer,
        'last_transfer_date': today,
        'updated_at': FieldValue.serverTimestamp(),
      });

      t.update(receiverRef, {
        'balance_yer': FieldValue.increment(amountYer),
        'updated_at': FieldValue.serverTimestamp(),
      });

      final record = {
        'tx_id': txId,
        'sender_id': walletId,
        'receiver_id': receiverId.trim(),
        'amount_yer': amountYer,
        'net_deducted_yer': netDeduct,
        'agent_commission_yer': commission,
        'sender_role': sRole,
        'receiver_role': rRole,
        'tx_date': today,
        'created_at': FieldValue.serverTimestamp(),
      };

      t.set(txRef, record);
      return record;
    });
  }

  /// 7. تسييل مستحقات صاحب الشبكة من عداد الـ WAN إلى محفظته مباشرة
  Future<void> claimHostWanEarnings(int amountYer) async {
    final hostRef = _db.collection('hosts').doc(currentHostId);
    final walletRef = _db.collection('wallets').doc(walletId);

    await _db.runTransaction((t) async {
      final hSnap = await t.get(hostRef);
      if (!hSnap.exists) throw Exception("بيانات الشبكة غير موجودة");
      final int due = (hSnap.data()!['amount_due_yer'] ?? 0) as int;
      if (amountYer <= 0 || amountYer > due) {
        throw Exception("المبلغ المطلوب غير متاح في عداد المستحقات");
      }

      t.update(hostRef, {
        'amount_due_yer': FieldValue.increment(-amountYer),
      });
      t.update(walletRef, {
        'balance_yer': FieldValue.increment(amountYer),
        'updated_at': FieldValue.serverTimestamp(),
      });
    });
  }
}