import 'package:flutter/material.dart';

/// 品牌 Logo:笔记本电脑侧视 + 屏幕内向右共享箭头。
/// 与启动器图标(scripts/make_icons.py 生成的 screen_share 图形)同款。
class BrandLogo extends StatelessWidget {
  final double size;
  final Color background;
  final Color foreground;

  const BrandLogo({
    super.key,
    this.size = 52,
    this.background = const Color(0xFF2563EB),
    this.foreground = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: CustomPaint(painter: _LaptopSharePainter(foreground)),
    );
  }
}

class _LaptopSharePainter extends CustomPainter {
  final Color color;
  _LaptopSharePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final white = Paint()..color = color;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.055;

    // 白色图形整体下移 0.05:原纵向范围 0.20~0.72 的中心是 0.46,
    // 比方块中心 0.50 偏上,下移后范围 0.25~0.77、中心 0.51,视觉居中。
    // 屏幕:描边圆角矩形 (0.24,0.25)-(0.76,0.65)
    final screen = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.24, h * 0.25, w * 0.52, h * 0.40),
      Radius.circular(w * 0.035),
    );
    canvas.drawRRect(screen, stroke);

    // 屏幕内向右箭头:杆 (0.34,0.405)-(0.50,0.495) + 三角头
    final stem = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.34, h * 0.405, w * 0.16, h * 0.09),
      Radius.circular(w * 0.02),
    );
    canvas.drawRRect(stem, white);
    final tri = Path()
      ..moveTo(w * 0.49, h * 0.35)
      ..lineTo(w * 0.49, h * 0.55)
      ..lineTo(w * 0.635, h * 0.45)
      ..close();
    canvas.drawPath(tri, white);

    // 底座:(0.30,0.67)(0.70,0.67)(0.76,0.77)(0.24,0.77)
    final base = Path()
      ..moveTo(w * 0.30, h * 0.67)
      ..lineTo(w * 0.70, h * 0.67)
      ..lineTo(w * 0.76, h * 0.77)
      ..lineTo(w * 0.24, h * 0.77)
      ..close();
    canvas.drawPath(base, white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
