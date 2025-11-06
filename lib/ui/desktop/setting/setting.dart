/*
 * Copyright 2023 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/manager/hosts_manager.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/util/system_proxy.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/proxy_port_setting.dart';
import 'package:proxypin/ui/desktop/setting/about.dart';
import 'package:proxypin/ui/desktop/setting/external_proxy.dart';
import 'package:proxypin/ui/desktop/setting/hosts.dart';
import 'package:proxypin/ui/desktop/setting/request_block.dart';

import 'filter.dart';

///设置菜单
/// @author wanghongen
/// 2023/10/8
class Setting extends StatefulWidget {
  final ProxyServer proxyServer;

  const Setting({super.key, required this.proxyServer});

  @override
  State<Setting> createState() => _SettingState();
}

class _SettingState extends State<Setting> {
  late Configuration configuration;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    configuration = widget.proxyServer.configuration;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      builder: (context, controller, child) {
        return IconButton(
            icon: const Icon(Icons.settings, size: 21),
            tooltip: localizations.setting,
            style: IconButton.styleFrom(
              backgroundColor: controller.isOpen
                  ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5)
                  : null,
            ),
            onPressed: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            });
      },
      style: MenuStyle(
        shape: MaterialStateProperty.all(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        elevation: MaterialStateProperty.all(4),
      ),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            localizations.setting,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        const Divider(height: 1),
        _ProxyMenu(proxyServer: widget.proxyServer),
        const Divider(height: 1, thickness: 0.5),
        item(localizations.domainFilter, icon: Icons.filter_list, onPressed: hostFilter),
        item(localizations.hosts, icon: Icons.dns, onPressed: hosts),
        item(localizations.requestBlock, icon: Icons.block, onPressed: showRequestBlock),
        item(localizations.requestRewrite, icon: Icons.edit, onPressed: requestRewrite),
        item(localizations.requestMap, icon: Icons.map, onPressed: requestMap),
        item(localizations.script,
            icon: Icons.code,
            onPressed: () => MultiWindow.openWindow(localizations.script, 'ScriptWidget', size: const Size(800, 700))),
        item(localizations.externalProxy, icon: Icons.vpn_lock, onPressed: setExternalProxy),
        const Divider(height: 1, thickness: 0.5),
        item(localizations.about, icon: Icons.info_outline, onPressed: showAbout),
      ],
    );
  }

  Widget item(String text, {IconData? icon, VoidCallback? onPressed}) {
    return MenuItemButton(
        style: ButtonStyle(
          padding: MaterialStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        leadingIcon: icon != null
            ? Icon(icon, size: 18)
            : null,
        trailingIcon: const Icon(Icons.arrow_right, size: 18),
        onPressed: onPressed,
        child: Text(text, style: const TextStyle(fontSize: 14)));
  }

  void showAbout() {
    showDialog(context: context, builder: (context) => DesktopAbout());
  }

  ///设置外部代理地址
  void setExternalProxy() {
    showDialog(
        barrierDismissible: false,
        context: context,
        builder: (context) {
          return ExternalProxyDialog(configuration: widget.proxyServer.configuration);
        });
  }

  ///请求重写Dialog
  void requestRewrite() async {
    if (!mounted) return;
    MultiWindow.openWindow(localizations.requestRewrite, 'RequestRewriteWidget', size: const Size(800, 750));
  }

  ///请求本地映射
  void requestMap() async {
    if (!mounted) return;
    MultiWindow.openWindow(localizations.requestMap, 'RequestMapPage', size: const Size(800, 720));
  }

  ///show域名过滤Dialog
  void hostFilter() {
    showDialog(
        barrierDismissible: false, context: context, builder: (context) => FilterDialog(configuration: configuration));
  }

  ///show域名过滤Dialog
  void hosts() async {
    var hosts = await HostsManager.instance;
    if (!mounted) return;
    showDialog(barrierDismissible: false, context: context, builder: (context) => HostsDialog(hostsManager: hosts));
  }

  //请求屏蔽
  void showRequestBlock() async {
    var requestBlockManager = await RequestBlockManager.instance;
    if (!mounted) return;
    showDialog(
        barrierDismissible: false,
        context: context,
        builder: (context) => RequestBlock(requestBlockManager: requestBlockManager));
  }
}

///代理菜单
class _ProxyMenu extends StatefulWidget {
  final ProxyServer proxyServer;

  const _ProxyMenu({required this.proxyServer});

  @override
  State<StatefulWidget> createState() => _ProxyMenuState();
}

class _ProxyMenuState extends State<_ProxyMenu> {
  var textEditingController = TextEditingController();

  late Configuration configuration;
  bool changed = false;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    configuration = widget.proxyServer.configuration;
    textEditingController.text = configuration.proxyPassDomains;
    super.initState();
  }

  @override
  void dispose() {
    if (configuration.proxyPassDomains != textEditingController.text) {
      changed = true;
      configuration.proxyPassDomains = textEditingController.text;
      SystemProxy.setProxyPassDomains(configuration.proxyPassDomains);
    }

    if (changed) {
      configuration.flushConfig();
    }
    textEditingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SubmenuButton(
      style: ButtonStyle(
        padding: MaterialStateProperty.all(
          const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      leadingIcon: Icon(Icons.router, size: 18, color: Theme.of(context).colorScheme.primary),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: PortWidget(proxyServer: widget.proxyServer, textStyle: const TextStyle(fontSize: 13)),
        ),
        const Divider(thickness: 0.3, height: 8),
        _SwitchRow(
          icon: Icons.power_settings_new,
          label: localizations.systemProxy,
          value: configuration.enableSystemProxy,
          onChanged: (val) {
            widget.proxyServer.setSystemProxyEnable(val);
            configuration.enableSystemProxy = val;
            setState(() {
              changed = true;
            });
          },
        ),
        const Divider(thickness: 0.3, height: 8),
        _SwitchRow(
          icon: Icons.security,
          label: "SOCKS5",
          value: configuration.enableSocks5,
          onChanged: (val) {
            configuration.enableSocks5 = val;
            changed = true;
          },
        ),
        const Divider(thickness: 0.3, height: 8),
        _SwitchRow(
          icon: Icons.http,
          label: localizations.enabledHTTP2,
          value: configuration.enabledHttp2,
          onChanged: (val) {
            configuration.enabledHttp2 = val;
            changed = true;
          },
        ),
        const Divider(thickness: 0.3, height: 8),
        const SizedBox(height: 3),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: Row(children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.block, size: 16, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(localizations.proxyIgnoreDomain, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text("多个使用;分割", style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                ],
              ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(localizations.reset),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onPressed: () {
                  textEditingController.text = SystemProxy.proxyPassDomains;
                },
              ),
            ])),
        const SizedBox(height: 8),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                  textInputAction: TextInputAction.done,
                  style: const TextStyle(fontSize: 13),
                  controller: textEditingController,
                  decoration: const InputDecoration(
                      contentPadding: EdgeInsets.all(12),
                      border: InputBorder.none,
                      constraints: BoxConstraints(minWidth: 190, maxWidth: 190)),
                  maxLines: 5,
                  minLines: 1),
            )),
        const SizedBox(height: 10),
      ],
      child: Padding(
          padding: const EdgeInsets.only(left: 0),
          child: Text(localizations.proxy, style: const TextStyle(fontSize: 14))),
    );
  }
}

class _SwitchRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_SwitchRow> createState() => _SwitchRowState();
}

class _SwitchRowState extends State<_SwitchRow> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 4),
      child: Row(
        children: [
          Icon(widget.icon, size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(widget.label, style: const TextStyle(fontSize: 14)),
          ),
          Transform.scale(
            scale: 0.75,
            child: Switch(
              value: widget.value,
              onChanged: (val) {
                widget.onChanged(val);
                setState(() {});
              },
            ),
          ),
          const SizedBox(width: 5),
        ],
      ),
    );
  }
}
