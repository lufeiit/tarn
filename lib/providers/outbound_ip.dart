import 'dart:convert';
import 'dart:io';

import 'package:tarn/common/constant.dart';
import 'package:tarn/common/service_probe.dart';
import 'package:tarn/models/models.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'core.dart';
import 'route_state.dart';
import 'routed_probe.dart';

part 'generated/outbound_ip.g.dart';

/// Keyed by the outbound a lookup pins: a node name, `DIRECT`, or
/// [routedOutbound] for whatever the rules pick right now.
@Riverpod(keepAlive: true)
class OutboundIpProbe extends _$OutboundIpProbe
    with RoutedProbe<String, IpInfo> {
  @override
  RoutedProbeState<String, IpInfo> build() => buildProbe();

  @override
  Future<Map<String, ProbeAnswer<IpInfo>>> probe(
    String target,
    RouteState route,
  ) async {
    final proxyName = target == routedOutbound && !route.proxied
        ? directOutbound
        : target;
    final result = await lookupOutboundIp(
      ref.read(coreHandlerProvider),
      proxyName,
    );
    final value = parseOutboundIp(result);
    final exit = result.chains.firstOrNull;
    return {
      target: ProbeAnswer(
        value: value,
        coreEpoch: result.coreEpoch,
        routeVersion: result.routeVersion,
        hits: result.hits,
        timedOut: result.error == probeErrorTimeout,
      ),
      // A node leaves through the same address whatever it is asked for.
      if (value != null && exit != null && exit != target)
        exit: ProbeAnswer(
          value: value,
          coreEpoch: result.coreEpoch,
          routeVersion: result.routeVersion,
          hits: result.nodeHits,
        ),
    };
  }
}

/// 没开代理时的「当前出口」：内核住在 VPN 扩展里，断开 VPN 就没有内核可问，
/// 卡片会一直空着。这里由 App 自己直连探测一次，显示本机网络自己的出口。
///
/// 只在 iOS 且未运行时使用（见 CurrentOutboundCard）；开着代理时这个请求也会
/// 被 TUN 接管，所以不能拿它当代理出口。
final directOutboundIpProvider = FutureProvider.autoDispose<IpInfo?>((
  ref,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  try {
    for (final url in ipInfoSources.keys) {
      try {
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set(HttpHeaders.userAgentHeader, browserUa);
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          continue;
        }
        final body = await response.transform(utf8.decoder).join();
        final info = parseOutboundIp(OutboundIpResult(url: url, body: body));
        if (info != null) {
          return info;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  } finally {
    client.close(force: true);
  }
});
