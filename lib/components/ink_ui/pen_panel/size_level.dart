/// The pen panel's size number (1 to 100) for a pen [size] in the pen's own
/// range [min]..[max].
int sizeToLevel(double size, {required double min, required double max}) =>
    (1 + (size - min) / (max - min) * 99).round().clamp(1, 100);

/// The pen size for the panel's [level]: 1 is [min], 100 is [max]. There is no
/// rounding to the pen's size step, so the number set is the number read back
/// (`sizeToLevel(levelToSize(level)) == level`).
double levelToSize(int level, {required double min, required double max}) =>
    min + (level.clamp(1, 100) - 1) / 99 * (max - min);
