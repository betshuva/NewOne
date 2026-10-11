function normalizeQuestionSelection(question) {
  if (!question || typeof question !== 'object' || Array.isArray(question))
    throw new Error('שאלה אינה תקינה');
  if (Object.hasOwn(question, 'allowMultiple') && typeof question.allowMultiple !== 'boolean')
    throw new Error('האפשרות לבחירת מספר תשובות אינה תקינה');
  return question.allowMultiple === true ? { allowMultiple: true } : {};
}

function surveyQuestionContent(questions) {
  return (Array.isArray(questions) ? questions : []).map(question => ({
    text: question.text, options: question.options,
    ...(question.allowMultiple === true ? { allowMultiple: true } : {}),
  }));
}

function normalizeSurveyAnswers(questions, answers) {
  if (!answers || typeof answers !== 'object' || Array.isArray(answers))
    throw new Error('יש לענות על כל שאלות הסקר');
  const clean = {};
  for (const [index, question] of questions.entries()) {
    const answer = answers[index];
    const options = Array.isArray(question.options) ? question.options : [];
    if (question.allowMultiple === true) {
      // Older clients send one selected option as a string, which is also a
      // valid one-choice response to a question allowing several choices.
      const selected = typeof answer === 'string' ? [answer] : answer;
      if (!Array.isArray(selected) || !selected.length || selected.length > options.length ||
          new Set(selected).size !== selected.length ||
          selected.some(value => typeof value !== 'string' || !options.includes(value)))
        throw new Error('יש לבחור לפחות תשובה אחת תקינה לכל שאלה');
      clean[index] = [...new Set(options)].filter(value => selected.includes(value));
    } else {
      if (typeof answer !== 'string' || !options.includes(answer))
        throw new Error('יש לבחור תשובה אחת תקינה לכל שאלה');
      clean[index] = answer;
    }
  }
  return clean;
}

module.exports = { normalizeQuestionSelection, surveyQuestionContent, normalizeSurveyAnswers };
