import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../blocs/duplicate_finder_bloc.dart';
import '../blocs/duplicate_finder_event.dart';
import '../blocs/duplicate_finder_state.dart';
import '../widgets/directory_selector.dart';
import '../widgets/scan_progress.dart';
import '../widgets/duplicate_list.dart';
import '../widgets/scan_summary.dart';
import 'recycle_bin_screen.dart';
import 'restored_files_screen.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    _checkPermissionsAndLoadDirectories();
  }

  Future<void> _checkPermissionsAndLoadDirectories() async {
    // For mobile platforms, check permissions. For desktop, load directly.
    if (Platform.isAndroid || Platform.isIOS) {
      if (await _hasStoragePermission()) {
        context.read<DuplicateFinderBloc>().add(LoadAvailableDirectories());
      }
    } else {
      // Desktop platforms don't need permission checks
      context.read<DuplicateFinderBloc>().add(LoadAvailableDirectories());
    }
  }

  Future<bool> _hasStoragePermission() async {
    if (Platform.isAndroid) {
      var storageStatus = await Permission.storage.status;
      var manageStorageStatus = await Permission.manageExternalStorage.status;
      return storageStatus.isGranted || manageStorageStatus.isGranted;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('DupFile Finder'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () {
              context.read<DuplicateFinderBloc>().add(LoadAvailableDirectories());
            },
            tooltip: 'Refresh directories',
          ),
          if (Platform.isAndroid)
            IconButton(
              icon: Icon(Icons.delete_outline),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => RecycleBinScreen()),
                );
              },
              tooltip: 'Recycle Bin',
            ),
          IconButton(
            icon: Icon(Icons.folder_special),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => RestoredFilesScreen()),
              );
            },
            tooltip: 'Restored Files',
          ),
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: () async {
              await openAppSettings();
            },
            tooltip: 'App settings',
          ),
        ],
      ),
      body: BlocBuilder<DuplicateFinderBloc, DuplicateFinderState>(
        builder: (context, state) {
          if (state is DuplicateFinderInitial) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Initializing...'),
                ],
              ),
            );
          }

          if (state is DuplicateFinderError) {
            return Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 64,
                      color: Colors.red[400],
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Error',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    SizedBox(height: 8),
                    Text(
                      state.message,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () {
                        context.read<DuplicateFinderBloc>().add(LoadAvailableDirectories());
                      },
                      icon: Icon(Icons.refresh),
                      label: Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          return SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Directory Selector
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Select Directory to Scan',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        SizedBox(height: 16),
                        DirectorySelector(),
                      ],
                    ),
                  ),
                ),

                SizedBox(height: 16),

                // Scan Progress
                if (state is DuplicateFinderScanning)
                  Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: ScanProgress(),
                    ),
                  ),

                // Scan Summary
                if (state is DuplicateFinderCompleted)
                  Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: ScanSummary(),
                    ),
                  ),

                SizedBox(height: 16),

                // Duplicate Files List
                if (state is DuplicateFinderCompleted && state.duplicates.isNotEmpty)
                  Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Duplicate Files',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          SizedBox(height: 16),
                          DuplicateList(),
                        ],
                      ),
                    ),
                  ),

                // No duplicates found
                if (state is DuplicateFinderCompleted && state.duplicates.isEmpty)
                  Card(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Column(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            size: 64,
                            color: Colors.green[400],
                          ),
                          SizedBox(height: 16),
                          Text(
                            'No Duplicates Found',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Your selected directory is clean!',
                            style: Theme.of(context).textTheme.bodyLarge,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),

                // Quick Actions
                Card(
                  elevation: 4,
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.touch_app, color: Theme.of(context).colorScheme.primary),
                            SizedBox(width: 8),
                            Text(
                              'Quick Actions',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (context) => RecycleBinScreen()),
                                  );
                                },
                                icon: Icon(Icons.delete_outline),
                                label: Text('Recycle Bin'),
                                style: ElevatedButton.styleFrom(
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (context) => RestoredFilesScreen()),
                                  );
                                },
                                icon: Icon(Icons.folder_special),
                                label: Text('Restored Files'),
                                style: ElevatedButton.styleFrom(
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () async {
                                  await openAppSettings();
                                },
                                icon: Icon(Icons.settings),
                                label: Text('App Settings'),
                                style: ElevatedButton.styleFrom(
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}