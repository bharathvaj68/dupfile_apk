import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';
import '../models/duplicate_file.dart';
import 'recycle_bin_service.dart';

class FileService {
  static const int _chunkSize = 8192; // 8KB chunks for reading files
  final RecycleBinService _recycleBinService = RecycleBinService();

  Future<List<String>> getAvailableDirectories() async {
    List<String> directories = [];

    try {
      // Check permissions first for mobile platforms
      if (!kIsWeb && Platform.isAndroid) {
        var status = await Permission.storage.status;
        var manageStatus = await Permission.manageExternalStorage.status;

        if (!status.isGranted && !manageStatus.isGranted) {
          throw Exception('Storage permission not granted');
        }
      }

      if (Platform.isAndroid) {
        // For Android, try to get common directories
        try {
          // External storage directory
          var externalDir = Directory('/storage/emulated/0');
          if (await externalDir.exists()) {
            directories.add(externalDir.path);
          }

          // Common user directories
          var commonDirs = [
            '/storage/emulated/0/Download',
            '/storage/emulated/0/Downloads',
            '/storage/emulated/0/Pictures',
            '/storage/emulated/0/DCIM',
            '/storage/emulated/0/Documents',
            '/storage/emulated/0/Music',
            '/storage/emulated/0/Movies',
          ];

          for (String dirPath in commonDirs) {
            var dir = Directory(dirPath);
            if (await dir.exists()) {
              directories.add(dirPath);
            }
          }
        } catch (e) {
          print('Error accessing external storage: $e');
        }

        // App-specific directories (always accessible)
        try {
          var appDir = await getApplicationDocumentsDirectory();
          directories.add(appDir.path);

          var externalAppDir = await getExternalStorageDirectory();
          if (externalAppDir != null) {
            directories.add(externalAppDir.path);
          }
        } catch (e) {
          print('Error getting app directories: $e');
        }
      } else if (Platform.isIOS) {
        // For iOS, use app-specific directories
        try {
          var documentsDir = await getApplicationDocumentsDirectory();
          directories.add(documentsDir.path);

          // Try to get other iOS directories
          var supportDir = await getApplicationSupportDirectory();
          directories.add(supportDir.path);

          // Library directory
          var libraryDir = await getLibraryDirectory();
          directories.add(libraryDir.path);

        } catch (e) {
          print('Error getting iOS directories: $e');
        }
      } else if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
        // For other platforms
        try {
          var documentsDir = await getApplicationDocumentsDirectory();
          directories.add(documentsDir.path);

          if (Platform.isMacOS || Platform.isLinux) {
            var homeDir = Platform.environment['HOME'];
            if (homeDir != null) {
              directories.add(homeDir);
              // For Linux, add common directories
              var commonLinuxDirs = [
                path.join(homeDir, 'Downloads'),
                path.join(homeDir, 'Documents'),
                path.join(homeDir, 'Pictures'),
                path.join(homeDir, 'Desktop'),
                path.join(homeDir, 'Videos'),
                path.join(homeDir, 'Music'),
              ];

              for (String dirPath in commonLinuxDirs) {
                if (await Directory(dirPath).exists()) {
                  directories.add(dirPath);
                }
              }

              // Add current workspace directory for Replit
              if (Platform.isLinux) {
                var workspaceDir = Directory.current.path;
                directories.add(workspaceDir);
              }
            }
          } else if (Platform.isWindows) {
            var homeDir = Platform.environment['USERPROFILE'];
            if (homeDir != null) {
              directories.add(homeDir);
              directories.add(path.join(homeDir, 'Downloads'));
              directories.add(path.join(homeDir, 'Documents'));
              directories.add(path.join(homeDir, 'Pictures'));
            }
          }
        } catch (e) {
          print('Error getting directories: $e');
        }
      } else if (kIsWeb) {
        // For web, we can only work with selected directories
        try {
          var documentsDir = await getApplicationDocumentsDirectory();
          directories.add(documentsDir.path);
        } catch (e) {
          print('Error getting web directories: $e');
        }
      }
    } catch (e) {
      print('Error in getAvailableDirectories: $e');
      rethrow;
    }

    // Remove duplicates and non-existent directories
    var uniqueDirs = directories.toSet().toList();
    var existingDirs = <String>[];

    for (String dir in uniqueDirs) {
      try {
        if (await Directory(dir).exists()) {
          existingDirs.add(dir);
        }
      } catch (e) {
        print('Error checking directory $dir: $e');
      }
    }

    return existingDirs;
  }

  Future<List<DuplicateFile>> scanForDuplicates(
    String directoryPath, {
    Function(String)? onProgress,
    Function(int)? onFileCount,
    Function(int)? onDuplicatesFound,
  }) async {
    try {
      onProgress?.call('Starting scan...');

      // Check if directory exists and is accessible
      var directory = Directory(directoryPath);
      if (!await directory.exists()) {
        throw Exception('Directory does not exist: $directoryPath');
      }

      // Get all files
      onProgress?.call('Finding files...');
      var allFiles = await _getAllFiles(directory);
      onFileCount?.call(allFiles.length);

      if (allFiles.isEmpty) {
        return [];
      }

      // Group files by size first (quick filter)
      onProgress?.call('Grouping files by size...');
      var sizeGroups = <int, List<File>>{};

      for (var file in allFiles) {
        try {
          var stat = await file.stat();
          var size = stat.size;

          if (size > 0) { // Skip empty files
            sizeGroups.putIfAbsent(size, () => []).add(file);
          }
        } catch (e) {
          print('Error getting file stats for ${file.path}: $e');
        }
      }

      // Only process groups with multiple files
      var duplicateGroups = sizeGroups.values
          .where((group) => group.length > 1)
          .toList();

      if (duplicateGroups.isEmpty) {
        return [];
      }

      // Calculate hashes for potential duplicates
      var duplicates = <DuplicateFile>[];
      var processedFiles = 0;
      var totalFiles = duplicateGroups.fold<int>(0, (sum, group) => sum + group.length);

      for (var group in duplicateGroups) {
        onProgress?.call('Processing group of ${group.length} files...');

        var hashGroups = <String, List<File>>{};

        for (var file in group) {
          try {
            var hash = await _calculateFileHash(file);
            hashGroups.putIfAbsent(hash, () => []).add(file);

            processedFiles++;
            if (processedFiles % 10 == 0) {
              onProgress?.call('Processed $processedFiles of $totalFiles files...');
            }
          } catch (e) {
            print('Error calculating hash for ${file.path}: $e');
          }
        }

        // Add groups with multiple files as duplicates
        for (var hashGroup in hashGroups.values) {
          if (hashGroup.length > 1) {
            var stat = await hashGroup.first.stat();
            var duplicateFile = DuplicateFile(
              paths: hashGroup.map((f) => f.path).toList(),
              size: stat.size,
              hash: await _calculateFileHash(hashGroup.first),
              count: hashGroup.length,
            );
            duplicates.add(duplicateFile);
            // Notify about new duplicate group found
            onDuplicatesFound?.call(duplicates.length);
          }
        }
      }

      onProgress?.call('Scan completed. Found ${duplicates.length} duplicate groups.');
      return duplicates;

    } catch (e) {
      print('Error in scanForDuplicates: $e');
      rethrow;
    }
  }

  Future<List<File>> _getAllFiles(Directory directory) async {
    var files = <File>[];

    try {
      await for (var entity in directory.list(recursive: true, followLinks: false)) {
        try {
          if (entity is File) {
            // Skip hidden files and system files
            var fileName = path.basename(entity.path);
            if (!fileName.startsWith('.') && !fileName.startsWith('~')) {
              files.add(entity);
            }
          }
        } catch (e) {
          print('Error processing entity ${entity.path}: $e');
        }
      }
    } catch (e) {
      print('Error listing directory ${directory.path}: $e');
      // Try to handle permission errors gracefully
      if (e.toString().contains('Permission denied')) {
        throw Exception('Permission denied accessing directory: ${directory.path}');
      }
      rethrow;
    }

    return files;
  }

  Future<String> _calculateFileHash(File file) async {
    try {
      var bytes = await file.readAsBytes();
      var digest = md5.convert(bytes);
      return digest.toString();
    } catch (e) {
      print('Error calculating hash for ${file.path}: $e');
      rethrow;
    }
  }

  Future<bool> deleteFile(String filePath) async {
    try {
      if (kIsWeb) {
        // Web doesn't support file deletion
        throw Exception('File deletion not supported on web');
      }

      final recycleBinService = RecycleBinService();
      return await recycleBinService.moveToRecycleBin(filePath);
    } catch (e) {
      print('Error deleting file $filePath: $e');
      return false;
    }
  }

  Future<bool> deleteDuplicateGroup(DuplicateFile duplicateGroup, {bool keepOldest = true}) async {
    try {
      if (keepOldest) {
        return await deleteGroupKeepOldest(duplicateGroup);
      } else {
        return await deleteGroupKeepNewest(duplicateGroup);
      }
    } catch (e) {
      print('Error deleting duplicate group: $e');
      return false;
    }
  }

  // Helper method to get duplicate bin directory
  Future<Directory> _getDupBinDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dupBinDir = Directory('${appDir.path}/DupBin');
    if (!await dupBinDir.exists()) {
      await dupBinDir.create(recursive: true);
    }
    return dupBinDir;
  }

// Delete duplicate group keeping the oldest file
Future<bool> deleteGroupKeepOldest(DuplicateFile duplicateGroup) async {
  try {
    final dupBin = await _getDupBinDirectory();

    if (duplicateGroup.paths.length <= 1) return true;

    // Map each file path to its last modified date (safely)
    final fileDateMap = <String, DateTime>{};
    for (final filePath in duplicateGroup.paths) {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          fileDateMap[filePath] = await file.lastModified();
        }
      } catch (e) {
        continue; // Skip unreadable or missing files
      }
    }

    if (fileDateMap.isEmpty) return false;

    // Identify the oldest file to keep
    final oldestPath = fileDateMap.entries.reduce((a, b) => 
        a.value.isBefore(b.value) ? a : b).key;

    // Delete all files except the oldest one
    for (final filePath in duplicateGroup.paths) {
      if (filePath == oldestPath) continue;

      final file = File(filePath);
      if (await file.exists()) {
        try {
          // Use RecycleBinService to properly move file
          await _recycleBinService.moveToRecycleBin(filePath);
        } catch (e) {
          print('Failed to move file $filePath: $e');
          continue;
        }
      }
    }

    return true;
  } catch (e) {
    print('Error in deleteGroupKeepOldest: $e');
    return false;
  }
}

// Delete duplicate group keeping the newest file
Future<bool> deleteGroupKeepNewest(DuplicateFile duplicateGroup) async {
  try {
    final dupBin = await _getDupBinDirectory();

    if (duplicateGroup.paths.length <= 1) return true;

    // Map each file path to its last modified date (safely)
    final fileDateMap = <String, DateTime>{};
    for (final filePath in duplicateGroup.paths) {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          fileDateMap[filePath] = await file.lastModified();
        }
      } catch (e) {
        continue; // Skip unreadable or missing files
      }
    }

    if (fileDateMap.isEmpty) return false;

    // Identify the newest file to keep
    final newestPath = fileDateMap.entries.reduce((a, b) =>
        a.value.isAfter(b.value) ? a : b).key;

    // Delete all files except the newest one
    for (final filePath in duplicateGroup.paths) {
      if (filePath == newestPath) continue;
      await _recycleBinService.moveToRecycleBin(filePath);
    }

    return true;
  } catch (e) {
    print('Error in deleteGroupKeepNewest: $e');
    return false;
  }
}

  Future<int> getFileSize(String filePath) async {
    try {
      var file = File(filePath);
      var stat = await file.stat();
      return stat.size;
    } catch (e) {
      print('Error getting file size for $filePath: $e');
      return 0;
    }
  }

  String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}