/// The subject particle for [word]: '이' after a final consonant, '가'
/// after a vowel, '이(가)' when the last character is not a Hangul syllable.
String subjectParticle(String word) {
  if (word.isEmpty) return '이(가)';
  final code = word.codeUnitAt(word.length - 1);
  if (code < 0xAC00 || code > 0xD7A3) return '이(가)';
  final hasFinalConsonant = (code - 0xAC00) % 28 != 0;
  return hasFinalConsonant ? '이' : '가';
}
