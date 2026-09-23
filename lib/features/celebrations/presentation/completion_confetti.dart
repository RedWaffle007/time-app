import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Measured from the supplied 30 fps WhatsApp reference: 42 visible frames.
const completionCelebrationDuration = Duration(milliseconds: 1400);

/// Intentionally denser than the reference while remaining one cheap canvas.
const completionConfettiParticleCount = 132;

enum CompletionConfettiShape { paper, ribbon, sparkle }

class CompletionConfettiSample {
  const CompletionConfettiSample({
    required this.x,
    required this.y,
    required this.rotation,
    required this.flip,
    required this.opacity,
    required this.scale,
  });

  final double x;
  final double y;
  final double rotation;
  final double flip;
  final double opacity;
  final double scale;
}

class CompletionConfettiParticle {
  const CompletionConfettiParticle({
    required this.originX,
    required this.originY,
    required this.velocityX,
    required this.velocityY,
    required this.gravity,
    required this.drag,
    required this.delaySeconds,
    required this.lifetimeSeconds,
    required this.initialRotation,
    required this.angularVelocity,
    required this.flipVelocity,
    required this.width,
    required this.height,
    required this.colorIndex,
    required this.shape,
  });

  final double originX;
  final double originY;
  final double velocityX;
  final double velocityY;
  final double gravity;
  final double drag;
  final double delaySeconds;
  final double lifetimeSeconds;
  final double initialRotation;
  final double angularVelocity;
  final double flipVelocity;
  final double width;
  final double height;
  final int colorIndex;
  final CompletionConfettiShape shape;

  CompletionConfettiSample sample(double progress) {
    final totalSeconds =
        completionCelebrationDuration.inMicroseconds /
        Duration.microsecondsPerSecond;
    final normalizedProgress = progress.clamp(0.0, 1.0).toDouble();
    final elapsed = normalizedProgress * totalSeconds - delaySeconds;
    if (elapsed <= 0 || elapsed >= lifetimeSeconds) {
      return CompletionConfettiSample(
        x: originX,
        y: originY,
        rotation: initialRotation,
        flip: 1,
        opacity: 0,
        scale: 0,
      );
    }

    // The burst starts at full velocity, loses horizontal energy to air drag,
    // and accelerates downward under gravity. This is deliberately ballistic,
    // not the old sine-wave rise/fall path.
    final horizontalTime = (1 - math.exp(-drag * elapsed)) / drag;
    final x = originX + velocityX * horizontalTime;
    final y = originY + velocityY * elapsed + 0.5 * gravity * elapsed * elapsed;
    final life = elapsed / lifetimeSeconds;
    final fade = life < 0.68 ? 1.0 : 1 - _smoothstep((life - 0.68) / 0.32);
    final scale = _smoothstep((elapsed / 0.075).clamp(0.0, 1.0).toDouble());

    return CompletionConfettiSample(
      x: x,
      y: y,
      rotation: initialRotation + angularVelocity * elapsed,
      flip: math.cos(flipVelocity * elapsed).abs().clamp(0.16, 1.0).toDouble(),
      opacity: fade.clamp(0.0, 1.0).toDouble(),
      scale: scale,
    );
  }
}

class CompletionConfettiBurst {
  CompletionConfettiBurst._(this.particles);

  final List<CompletionConfettiParticle> particles;

  factory CompletionConfettiBurst.seeded(
    int seed, {
    int count = completionConfettiParticleCount,
  }) {
    final random = math.Random(seed);
    final particles = <CompletionConfettiParticle>[];
    for (var index = 0; index < count; index++) {
      // Even lanes guarantee wide left/right coverage; noise keeps the burst
      // organic rather than fan-shaped. A few low-angle pieces immediately
      // occupy the lower half while the majority explode upward first.
      final lane = count == 1 ? 0.0 : (index / (count - 1)) * 2 - 1;
      final edgeBoost = 1.3 + 0.35 * random.nextDouble();
      final velocityX = lane * edgeBoost + (random.nextDouble() - 0.5) * 0.18;
      final isLowPiece = index % 8 == 0;
      final double velocityY;
      if (index == 0) {
        velocityY = 0.18;
      } else if (index == 1) {
        velocityY = -1.45;
      } else if (isLowPiece) {
        velocityY = -0.18 + random.nextDouble() * 0.36;
      } else {
        velocityY = -(0.72 + random.nextDouble() * 0.76);
      }
      final delay = random.nextDouble() * 0.055;
      final lifetime = index <= 1
          ? 1.4 - delay
          : math.min(1.02 + random.nextDouble() * 0.38, 1.4 - delay).toDouble();

      particles.add(
        CompletionConfettiParticle(
          originX: 0.5 + (random.nextDouble() - 0.5) * 0.055,
          originY: 0.54 + (random.nextDouble() - 0.5) * 0.045,
          velocityX: velocityX,
          velocityY: velocityY,
          gravity: switch (index) {
            0 => 2.2,
            1 => 1.8,
            _ => 1.72 + random.nextDouble() * 0.52,
          },
          drag: 0.16 + random.nextDouble() * 0.28,
          delaySeconds: delay,
          lifetimeSeconds: lifetime,
          initialRotation: random.nextDouble() * math.pi * 2,
          angularVelocity:
              (random.nextBool() ? 1 : -1) * (5.2 + random.nextDouble() * 10.5),
          flipVelocity: 8 + random.nextDouble() * 15,
          width: 5 + random.nextDouble() * 5.5,
          height: 9 + random.nextDouble() * 8,
          colorIndex: index % AppColors.completionCelebrationPaper.length,
          shape: CompletionConfettiShape.values[index % 3],
        ),
      );
    }
    return CompletionConfettiBurst._(List.unmodifiable(particles));
  }

  static int seedForEvent(String eventId) {
    // Stable FNV-1a rather than String.hashCode, whose implementation is not a
    // persisted contract. The same event therefore cannot visually jump when a
    // live Firestore snapshot re-emits it.
    var hash = 0x811C9DC5;
    for (final unit in eventId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7FFFFFFF;
    }
    return hash;
  }
}

class CompletionConfetti extends StatelessWidget {
  const CompletionConfetti({
    super.key,
    required this.progress,
    required this.burst,
  });

  final double progress;
  final CompletionConfettiBurst burst;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(painter: _CompletionConfettiPainter(progress, burst)),
    );
  }
}

class _CompletionConfettiPainter extends CustomPainter {
  const _CompletionConfettiPainter(this.progress, this.burst);

  final double progress;
  final CompletionConfettiBurst burst;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final particle in burst.particles) {
      final sample = particle.sample(progress);
      if (sample.opacity <= 0) continue;
      final paint = Paint()
        ..color = AppColors.completionCelebrationPaper[particle.colorIndex]
            .withValues(alpha: sample.opacity);
      canvas.save();
      canvas.translate(sample.x * size.width, sample.y * size.height);
      canvas.rotate(sample.rotation);
      canvas.scale(sample.flip * sample.scale, sample.scale);
      switch (particle.shape) {
        case CompletionConfettiShape.paper:
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset.zero,
                width: particle.width,
                height: particle.height,
              ),
              const Radius.circular(1.4),
            ),
            paint,
          );
          break;
        case CompletionConfettiShape.ribbon:
          final path = Path()
            ..moveTo(-particle.width / 2, -particle.height / 2)
            ..quadraticBezierTo(
              particle.width,
              -particle.height * 0.15,
              -particle.width / 2,
              particle.height / 2,
            );
          canvas.drawPath(
            path,
            paint
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.4
              ..strokeCap = StrokeCap.round,
          );
          break;
        case CompletionConfettiShape.sparkle:
          final radius = particle.height * 0.58;
          final path = Path()
            ..moveTo(0, -radius)
            ..lineTo(radius * 0.22, -radius * 0.22)
            ..lineTo(radius, 0)
            ..lineTo(radius * 0.22, radius * 0.22)
            ..lineTo(0, radius)
            ..lineTo(-radius * 0.22, radius * 0.22)
            ..lineTo(-radius, 0)
            ..lineTo(-radius * 0.22, -radius * 0.22)
            ..close();
          canvas.drawPath(path, paint);
          break;
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CompletionConfettiPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.burst != burst;
}

double _smoothstep(double value) {
  final t = value.clamp(0.0, 1.0).toDouble();
  return t * t * (3 - 2 * t);
}
