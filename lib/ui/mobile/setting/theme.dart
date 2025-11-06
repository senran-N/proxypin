/*
 * Copyright 2023 Hongen Wang
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
import 'package:proxypin/ui/configuration.dart';

class MobileThemeSetting extends StatelessWidget {
  final AppConfiguration appConfiguration;

  const MobileThemeSetting({super.key, required this.appConfiguration});

  @override
  Widget build(BuildContext context) {
    AppLocalizations localizations = AppLocalizations.of(context)!;

    return PopupMenuButton<int>(
        tooltip: appConfiguration.themeMode.name,
        surfaceTintColor: Theme.of(context).colorScheme.onPrimary,
        offset: const Offset(150, 0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        itemBuilder: (BuildContext context) {
          return <PopupMenuEntry<int>>[
            PopupMenuItem<int>(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Tooltip(
                preferBelow: false,
                message: localizations.material3,
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SwitchListTile(
                    value: appConfiguration.useMaterial3,
                    onChanged: (bool value) {
                      appConfiguration.useMaterial3 = value;
                      Navigator.of(context).pop();
                    },
                    dense: true,
                    title: const Text("Material3", style: TextStyle(fontSize: 14)),
                  ),
                ),
              ),
            ),
            const PopupMenuDivider(height: 8),
            PopupMenuItem<int>(
              child: ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.cached, size: 18),
                ),
                dense: true,
                title: Text(localizations.followSystem, style: const TextStyle(fontSize: 14)),
              ),
              onTap: () => appConfiguration.themeMode = ThemeMode.system,
            ),
            PopupMenuItem<int>(
              child: ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.sunny, size: 18),
                ),
                dense: true,
                title: Text(localizations.themeLight, style: const TextStyle(fontSize: 14)),
              ),
              onTap: () => appConfiguration.themeMode = ThemeMode.light,
            ),
            PopupMenuItem<int>(
              child: ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.nightlight_outlined, size: 18),
                ),
                dense: true,
                title: Text(localizations.themeDark, style: const TextStyle(fontSize: 14)),
              ),
              onTap: () => appConfiguration.themeMode = ThemeMode.dark,
            ),
          ];
        },
        child: ListTile(
          title: Text(localizations.theme),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: getIcon(),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_drop_down, size: 20),
            ],
          ),
        ));
  }

  Icon getIcon() {
    switch (appConfiguration.themeMode) {
      case ThemeMode.system:
        return const Icon(Icons.cached);
      case ThemeMode.dark:
        return const Icon(Icons.nightlight_outlined);
      case ThemeMode.light:
        return const Icon(Icons.sunny);
    }
  }
}
