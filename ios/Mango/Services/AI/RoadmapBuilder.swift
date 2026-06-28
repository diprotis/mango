import Foundation
import SwiftData

/// Converts a generated `RoadmapDTO` into the SwiftData object graph and attaches
/// it to a book.
@MainActor
enum RoadmapBuilder {
    static func attach(_ dto: RoadmapDTO, to book: Book, in context: ModelContext) {
        let roadmap = Roadmap(title: dto.title, summary: dto.summary)
        book.roadmap = roadmap

        for (mIndex, milestoneDTO) in dto.milestones.enumerated() {
            let milestone = Milestone(
                title: milestoneDTO.title,
                subtitle: milestoneDTO.subtitle,
                order: mIndex
            )
            for (lIndex, lessonDTO) in milestoneDTO.lessons.enumerated() {
                let lesson = Lesson(
                    title: lessonDTO.title,
                    readingSummary: lessonDTO.readingSummary,
                    estimatedMinutes: max(1, lessonDTO.estimatedMinutes),
                    order: lIndex
                )
                // Reading is a first-class activity threaded through every lesson:
                // a curated slice to read in the user's own copy, always the first
                // step, synthesized from the lesson's readingSummary (ADR-0003).
                lesson.exercises.append(Self.makeReadingActivity(for: lessonDTO))
                for (eIndex, exerciseDTO) in lessonDTO.exercises.enumerated() {
                    let kind = ExerciseKind(rawValue: exerciseDTO.kind) ?? .reflection
                    // A model that already emits a "reading" exercise shouldn't double up.
                    guard kind != .reading else { continue }
                    let exercise = Exercise(
                        kind: kind,
                        prompt: exerciseDTO.prompt,
                        options: exerciseDTO.options ?? [],
                        answerIndex: exerciseDTO.answerIndex,
                        xp: exerciseDTO.xp > 0 ? exerciseDTO.xp : kind.baseXP,
                        order: eIndex + 1  // reading occupies order 0
                    )
                    lesson.exercises.append(exercise)
                }
                milestone.lessons.append(lesson)
            }
            roadmap.milestones.append(milestone)
        }
        context.insert(roadmap)
    }

    /// Builds the leading reading activity for a lesson, preferring the structured
    /// `reading` slice (locator + anchor quote + what-to-notice) when the model
    /// provided one, and falling back to the reading summary otherwise.
    /// Mango never shows the book's text (ADR-0001) — this only *instructs*.
    static func makeReadingActivity(for lesson: LessonDTO) -> Exercise {
        readingActivity(
            title: lesson.title,
            summary: lesson.readingSummary,
            locator: lesson.reading?.locator,
            anchorQuote: lesson.reading?.anchorQuote,
            whatToNotice: lesson.reading?.whatToNoticeWhileReading
        )
    }

    /// Shared reading-activity factory so generation (RoadmapBuilder) and the
    /// bundled sample (SeedData) produce identical reading steps. When a `locator`
    /// is present the prompt is a short headline ("Read: ‹locator›") and the
    /// structured fields are stored for distinct rendering; otherwise it falls back
    /// to the summary-based instruction (old roadmaps / model-omitted slices).
    static func readingActivity(
        title: String,
        summary: String,
        locator: String? = nil,
        anchorQuote: String? = nil,
        whatToNotice: String? = nil
    ) -> Exercise {
        let cleanLocator = locator?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAnchor = anchorQuote?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNotice = whatToNotice?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cue = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        let prompt: String
        if let cleanLocator, !cleanLocator.isEmpty {
            prompt = "Read: \(cleanLocator)"
        } else if cue.isEmpty {
            prompt = "Read the section for “\(title)” in your own copy."
        } else {
            prompt = "Read the section for “\(title)” in your own copy. \(cue)"
        }

        let exercise = Exercise(
            kind: .reading,
            prompt: prompt,
            xp: ExerciseKind.reading.baseXP,
            order: 0
        )
        // Only set structured fields when non-empty, so the fallback path (no slice)
        // leaves them nil and ExerciseRunnerView renders the simple hint.
        exercise.locator = cleanLocator?.isEmpty == false ? cleanLocator : nil
        exercise.anchorQuote = cleanAnchor?.isEmpty == false ? cleanAnchor : nil
        exercise.whatToNotice = cleanNotice?.isEmpty == false ? cleanNotice : nil
        return exercise
    }
}
