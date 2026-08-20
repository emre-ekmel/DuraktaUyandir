import 'package:durakta_uyandir/core/services/background_service.dart';
import 'package:durakta_uyandir/presentation/bloc/alarm_bloc.dart';
import 'package:durakta_uyandir/presentation/cubit/settings_cubit.dart';
import 'package:durakta_uyandir/presentation/pages/add_alarm_page.dart';
import 'package:durakta_uyandir/presentation/pages/alarm_ring_page.dart';
import 'package:durakta_uyandir/presentation/pages/home_page.dart';
import 'package:durakta_uyandir/presentation/pages/settings_page.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class MainPage extends StatefulWidget {
  // ignore: library_private_types_in_public_api
  static final GlobalKey<_MainPageState> globalKey = GlobalKey<_MainPageState>();

  MainPage({Key? key}) : super(key: globalKey);

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver {
  int _selectedIndex = 0;

  void switchTab(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  final List<Widget> _pages = [const HomePage(), const AddAlarmPage(), const SettingsPage()];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
    _checkAnalyticsConsent();
    _wireRingUiLaunchPath();
  }

  /// Wire the full-screen Ring UI launch paths:
  ///  - WARM: FSI launch / notification body tap while the app is alive, via
  ///    the foreground FLN response hook.
  ///  - COLD: app launched by the notification (checked once at startup via
  ///    getNotificationAppLaunchDetails).
  void _wireRingUiLaunchPath() {
    AlarmRingNavigator.contextProvider = () =>
        MainPage.globalKey.currentContext;
    BackgroundLocationService.ringUiRequestedCallback =
        (payload) => AlarmRingNavigator.maybeOpenForPayload(payload, null);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final details = await FlutterLocalNotificationsPlugin()
            .getNotificationAppLaunchDetails();
        if (details != null && details.didNotificationLaunchApp) {
          AlarmRingNavigator.maybeOpenForPayload(
            details.notificationResponse?.payload,
            null,
          );
        }
      } catch (_) {
        // Ring UI launch-path is best-effort; the notification actions work
        // regardless.
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-check permission + service state when the user returns from
      // OS settings or another app. This clears the permission banner
      // automatically once the user grants background location.
      context.read<AlarmBloc>().add(LoadAlarms());
    }
  }

  Future<void> _checkAnalyticsConsent() async {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final cubit = context.read<SettingsCubit>();
      if (cubit.state.isAnalyticsEnabled == null) {
        _showAnalyticsConsentDialog(cubit);
      }
    });
  }

  void _showAnalyticsConsentDialog(SettingsCubit cubit) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text("settings.analytics".tr()),
        content: Text("settings.analytics_consent_desc".tr()),
        actions: [
          TextButton(
            onPressed: () {
              cubit.setAnalyticsEnabled(false);
              Navigator.pop(ctx);
            },
            child: Text("common.no".tr()),
          ),
          FilledButton(
            onPressed: () {
              cubit.setAnalyticsEnabled(true);
              Navigator.pop(ctx);
            },
            child: Text("common.yes".tr()),
          ),
        ],
      ),
    );
  }

  Future<void> _checkPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.notification,
      Permission.locationWhenInUse,
    ].request();

    if (statuses[Permission.locationWhenInUse]?.isGranted ?? false) {
      if (await Permission.locationAlways.isDenied) {
        if (!mounted) return;

        await _showBackgroundPermissionDialog();
      }
    }
  }

  Future<void> _showBackgroundPermissionDialog() async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text("permissions.background_title".tr()),
        content: Text("permissions.background_desc".tr()),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
            },
            child: Text("permissions.later".tr()),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);

              final status = await Permission.locationAlways.request();

              if (!status.isGranted) {
                await openAppSettings();
              }
            },
            child: Text("add_alarm.open_settings".tr()),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selectedIndex == 1
          ? null
          : AppBar(title: const Text('Durakta Uyandır'), centerTitle: true),
      body: IndexedStack(index: _selectedIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home_filled),
            label: 'common.nav_home'.tr(),
          ),
          NavigationDestination(
            icon: const Icon(Icons.add_circle_outline),
            selectedIcon: const Icon(Icons.add_circle),
            label: 'common.nav_add'.tr(),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: 'common.nav_settings'.tr(),
          ),
        ],
      ),
    );
  }
}
