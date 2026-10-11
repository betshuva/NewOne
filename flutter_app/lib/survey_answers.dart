List<String> surveySelectedAnswers(dynamic answer) {
  if (answer is List) {
    return answer
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toList();
  }
  return answer is String && answer.isNotEmpty ? [answer] : [];
}

String surveyAnswerLabel(dynamic answer) =>
    surveySelectedAnswers(answer).join(' · ');

Map<String, int> surveyAnswerCounts(Map<String, dynamic> question,
    Iterable<Map<String, dynamic>> responses, int questionIndex) {
  final counts = <String, int>{
    for (final option in question['options'] as List? ?? [])
      option.toString(): 0,
  };
  for (final response in responses) {
    final answers = response['answers'];
    if (answers is! Map) continue;
    for (final answer
        in surveySelectedAnswers(answers['$questionIndex']).toSet()) {
      if (counts.containsKey(answer)) counts[answer] = counts[answer]! + 1;
    }
  }
  return counts;
}
