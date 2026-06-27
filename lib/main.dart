import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hidden_logo/hidden_logo.dart';
import 'package:image_magic_eraser/image_magic_eraser.dart';
import 'package:image_picker/image_picker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await InpaintingService.instance.initializeOrt(
    'assets/models/lama_fp32.onnx',
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'Flutter Demo', home: DemoPage());
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  // Image picker
  static final ImagePicker _imagePicker = ImagePicker();
  XFile? _selectedImage;
  Uint8List? _imageBytes;
  ImageProvider? _imageProvider;

  /// 保存的布局信息 (逻辑像素)
  double _notchWidth = 0;
  double _notchHeight = 0;

  // Maximum number of polygons
  final int _maxPolygons = 5;

  // Inpainting state
  bool _isInpainting = false;
  bool _useGpu = true;
  double? _lastExecutionTimeMs;
  StreamSubscription<ModelLoadingState>? _modelLoadingSubscription;

  // Polygon drawing controller
  List<List<Map<String, double>>> _polygons = [];

  @override
  void initState() {
    super.initState();

    // Subscribe to model loading state changes
    _modelLoadingSubscription = InpaintingService
        .instance
        .modelLoadingStateStream
        .listen((state) {
          if (!mounted) return;
          debugPrint('Model loading state: $state');
          setState(() {});
        });
  }

  @override
  void dispose() {
    _modelLoadingSubscription?.cancel();
    _clearImageResources();
    super.dispose();
  }

  /// Clear image resources to prevent memory leaks
  void _clearImageResources() {
    // Reset image provider to release memory
    if (_imageProvider != null) {
      if (_imageProvider is MemoryImage) {
        (_imageProvider as MemoryImage).evict();
      }
      _imageProvider = null;
    }

    // Clear image bytes reference
    _imageBytes = null;
    _selectedImage = null;
  }

  /// Pick image from gallery
  Future<void> _pickImage() async {
    try {
      final file = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      );
      if (file == null) return;

      // Clear previous image resources
      _clearImageResources();

      // Load the image and get its dimensions
      final bytes = await File(file.path).readAsBytes();
      final image = await decodeImageFromList(bytes);

      if (!mounted) return;

      setState(() {
        _selectedImage = file;
        _imageBytes = bytes;
        _imageProvider = MemoryImage(bytes);
      });

      _log('Image loaded: ${image.width}x${image.height}');

      // Dispose the decoded image as we don't need it anymore
      image.dispose();

      await _inpaintWithPolygons();
    } on Exception catch (e) {
      if (!mounted) return;
      _showError('Error picking image: $e');
    }
  }

  /// Inpaint with polygons
  Future<void> _inpaintWithPolygons() async {
    if (_imageBytes == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select an image')));
      return;
    }

    setState(() {
      _isInpainting = true;
      _lastExecutionTimeMs = null;
    });

    try {
      final decodedImage = await decodeImageFromList(_imageBytes!);

      // 解码图片获取实际像素尺寸
      final int imageWidth = decodedImage.width;
      final int imageHeight = decodedImage.height;
      decodedImage.dispose();

      if (!mounted) return;

      // 根据当前设备状态栏比例换算图片中需要擦除的区域高度
      final double statusBarHeight = MediaQuery.of(context).padding.top;
      final double screenHeight = MediaQuery.of(context).size.height;
      final double screenWidth = MediaQuery.of(context).size.width;

      final double yRatio = imageHeight / screenHeight;
      final double eraseHeight = statusBarHeight * yRatio;

      // x 轴比例（逻辑像素 → 图片像素）
      final double xRatio = screenWidth > 0 ? imageWidth / screenWidth : 1.0;

      // 左侧区域宽度与右侧区域起始位置 (逻辑像素)
      final double leftWidthLogical = (screenWidth - _notchWidth) / 2;
      final double rightStartLogical = (screenWidth + _notchWidth) / 2;

      final List<List<Map<String, double>>> polygonsData = [
        // 左侧 (时间区域)
        [
          {'x': 0.0, 'y': 0.0},
          {'x': leftWidthLogical * xRatio, 'y': 0.0},
          {'x': leftWidthLogical * xRatio, 'y': eraseHeight},
          {'x': 0.0, 'y': eraseHeight},
        ],
        // 右侧 (信号 / 电量区域)
        [
          {'x': rightStartLogical * xRatio, 'y': 0.0},
          {'x': imageWidth.toDouble(), 'y': 0.0},
          {'x': imageWidth.toDouble(), 'y': eraseHeight},
          {'x': rightStartLogical * xRatio, 'y': eraseHeight},
        ],
      ];

      setState(() {
        _polygons = polygonsData;
      });

      print("polygonsData ${polygonsData}");

      final stopwatch = Stopwatch()..start();

      final result = await InpaintingService.instance.inpaint(
        _imageBytes!,
        polygonsData,
        config: InpaintingConfig(useGpu: _useGpu),
      );

      stopwatch.stop();
      final executionTime = stopwatch.elapsedMilliseconds;

      // Convert ui.Image to Uint8List
      final ByteData? byteData = await result.toByteData(
        format: ui.ImageByteFormat.png,
      );

      // Dispose the result image now that we have the byte data
      result.dispose();

      final Uint8List outputBytes = byteData!.buffer.asUint8List();

      // Clear previous image provider
      if (_imageProvider != null && _imageProvider is MemoryImage) {
        (_imageProvider as MemoryImage).evict();
      }

      setState(() {
        _imageBytes = outputBytes;
        _imageProvider = MemoryImage(outputBytes);
        _isInpainting = false;
        _lastExecutionTimeMs = executionTime.toDouble();
      });
    } catch (e) {
      setState(() {
        _isInpainting = false;
        _lastExecutionTimeMs = null;
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error during inpainting: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Show error message
  void _showError(String message) {
    debugPrint(message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  /// Log debug information
  void _log(String message) {
    debugPrint('[DemoPage] $message');
  }

  @override
  Widget build(BuildContext context) {
    final modelState = InpaintingService.instance.modelLoadingState;

    return HiddenLogo(
      notchBuilder: (context, constraints) {
        _notchWidth = constraints.maxWidth;
        _notchHeight = constraints.maxHeight;
        return SizedBox.shrink();
      },
      dynamicIslandBuilder: (context, constraints) {
        _notchWidth = constraints.maxWidth;
        _notchHeight = constraints.maxHeight;
        return SizedBox.shrink();
      },
      body: Scaffold(
        appBar: AppBar(
          title: const Text("Image Magic Eraser"),
          centerTitle: true,
        ),
        body: SafeArea(
          child: modelState == ModelLoadingState.loading
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text("Loading model..."),
                    ],
                  ),
                )
              : _buildMainContent(),
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    return Column(
      children: [
        // Control panel
        _buildControlPanel(),

        // Drawing area
        Expanded(
          child: _selectedImage == null
              ? _buildEmptyState()
              : _buildDrawingArea(),
        ),

        // Status bar
        _buildStatusBar(),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.image_search, size: 80, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            "No image selected",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            "Select an image to start erasing objects",
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _pickImage,
            icon: const Icon(Icons.add_photo_alternate),
            label: const Text("Select Image"),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawingArea() {
    return Center(
      child: _isInpainting
          ? const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text("Erasing selected areas..."),
              ],
            )
          : Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
                color: Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              margin: const EdgeInsets.all(8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _imageProvider != null
                    ? Image(image: _imageProvider!, fit: BoxFit.contain)
                    : null,
              ),
            ),
    );
  }

  Widget _buildControlPanel() {
    return Card(
      margin: const EdgeInsets.all(8.0),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.start,
              children: [
                ElevatedButton.icon(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.image, size: 18),
                  label: const Text('Select Image'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _inpaintWithPolygons,
                  icon: const Icon(Icons.auto_fix_high, size: 18),
                  label: const Text('Inpaint'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    textStyle: const TextStyle(fontSize: 13),
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    foregroundColor: Theme.of(
                      context,
                    ).colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.layers, size: 16),
          const SizedBox(width: 4),
          Text("Selections: ${_polygons.length}/$_maxPolygons"),
          const Spacer(),
          if (_lastExecutionTimeMs != null) ...[
            const Icon(Icons.timer, size: 16),
            const SizedBox(width: 4),
            Text("${(_lastExecutionTimeMs! / 1000).toStringAsFixed(1)}s"),
            const SizedBox(width: 16),
          ],
          Switch(
            value: _useGpu,
            onChanged: (value) => setState(() => _useGpu = value),
          ),
          Text(_useGpu ? 'GPU' : 'CPU'),
        ],
      ),
    );
  }
}
