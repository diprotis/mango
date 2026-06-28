import SwiftUI

/// Presents a single activity and reports the awarded XP back to the lesson:
/// reading is self-attested ("I've read this", no text shown — ADR-0001), quizzes
/// grade locally, and reflections/applications grade via the AI service.
struct ExerciseRunnerView: View {
    @Environment(AppModel.self) private var app
    let exercise: Exercise
    let onComplete: (Int) -> Void

    @State private var chosen: Int?
    @State private var answer = ""
    @State private var grading = false
    @State private var graded = false
    @State private var feedback = ""
    @State private var awardedXP = 0
    @State private var score: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Tag(exercise.kind.title, systemImage: exercise.kind.symbol, color: exercise.kind.tint)
            Text(exercise.prompt)
                .font(Typo.title3)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            switch exercise.kind {
            case .reading: readingHint
            case .quiz: quizOptions
            case .reflection, .application: freeText
            }

            if exercise.kind == .reading {
                // Self-attested: one tap completes, no grading or feedback beat.
                if graded {
                    Label("Marked as read", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.success)
                    Button("Continue") { complete() }.buttonStyle(.mangoPrimary)
                } else {
                    Button {
                        awardedXP = exercise.xp
                        graded = true
                        Haptics.success()
                        complete()
                    } label: {
                        Label("I've read this", systemImage: "checkmark")
                    }
                    .buttonStyle(.mangoPrimary)
                }
            } else if graded {
                feedbackCard
                Button("Continue") { complete() }.buttonStyle(.mangoPrimary)
            } else {
                Button {
                    submit()
                } label: {
                    if grading {
                        HStack { ProgressView().tint(Palette.onAccent); Text("Checking…") }
                    } else {
                        Text(exercise.kind == .quiz ? "Check answer" : "Submit")
                    }
                }
                .buttonStyle(.mangoPrimary(enabled: canSubmit && !grading))
                .disabled(!canSubmit || grading)
            }
        }
        .onAppear(perform: restoreIfCompleted)
    }

    private var quizOptions: some View {
        VStack(spacing: 10) {
            ForEach(Array(exercise.options.enumerated()), id: \.offset) { idx, option in
                Button {
                    if !graded { chosen = idx; Haptics.selection() }
                } label: {
                    HStack {
                        Text(option).foregroundStyle(Palette.textPrimary)
                        Spacer()
                        if graded, idx == exercise.answerIndex {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
                        } else if graded, idx == chosen {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.danger)
                        } else if chosen == idx {
                            Image(systemName: "largecircle.fill.circle").foregroundStyle(Palette.accent)
                        }
                    }
                    .padding(14)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(borderColor(idx), lineWidth: chosen == idx || (graded && idx == exercise.answerIndex) ? 2 : 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var readingHint: some View {
        Label("Read this in your own copy (Kindle, print, or library), then mark it done.", systemImage: "book.closed")
            .font(.footnote)
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var freeText: some View {
        TextEditor(text: $answer)
            .frame(minHeight: 150)
            .padding(8)
            .scrollContentBackground(.hidden)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
            .disabled(graded)
    }

    private var feedbackCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("+\(awardedXP) XP", systemImage: "star.fill").foregroundStyle(Palette.xp)
                    Spacer()
                    if let score { Text("\(Int(score * 100))%").foregroundStyle(Palette.textSecondary) }
                }
                .font(.subheadline.weight(.semibold))
                Text(feedback).font(.callout).foregroundStyle(Palette.textPrimary)
            }
        }
    }

    private func borderColor(_ idx: Int) -> Color {
        if graded, idx == exercise.answerIndex { return Palette.success }
        if graded, idx == chosen { return Palette.danger }
        return chosen == idx ? Palette.accent : Palette.border
    }

    private var canSubmit: Bool {
        switch exercise.kind {
        case .reading: return true  // completed via "I've read this", not the submit path
        case .quiz: return chosen != nil
        case .reflection, .application: return answer.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
        }
    }

    private func submit() {
        if exercise.kind == .quiz {
            let correct = chosen == exercise.answerIndex
            awardedXP = correct ? exercise.xp : 0
            score = correct ? 1 : 0
            feedback = correct
                ? "Correct! \(exercise.kind.title) complete."
                : "Not quite. The answer was: \(exercise.options[safe: exercise.answerIndex ?? -1] ?? "—")"
            correct ? Haptics.success() : Haptics.warning()
            graded = true
            return
        }

        grading = true
        Task {
            let result = try? await app.ai.grade(kind: exercise.kind, prompt: exercise.prompt, answer: answer)
            awardedXP = result?.xpAwarded ?? exercise.xp
            score = result?.score
            feedback = result?.feedback ?? "Thanks for putting in the work."
            graded = true
            grading = false
            Haptics.success()
        }
    }

    private func restoreIfCompleted() {
        guard exercise.isCompleted else { return }
        graded = true
        awardedXP = 0
        chosen = exercise.chosenIndex
        answer = exercise.userAnswer ?? ""
        score = exercise.score
        feedback = exercise.feedback ?? "You've completed this."
    }

    private func complete() {
        exercise.chosenIndex = chosen
        exercise.userAnswer = answer.isEmpty ? nil : answer
        exercise.score = score
        exercise.feedback = feedback
        if exercise.completedAt == nil { exercise.completedAt = .now }
        onComplete(awardedXP)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
