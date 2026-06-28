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

    /// Builds the leading reading activity for a lesson from its reading summary.
    /// The prompt *instructs* what to read (Mango never shows the text — ADR-0001).
    static func makeReadingActivity(for lesson: LessonDTO) -> Exercise {
        readingActivity(title: lesson.title, summary: lesson.readingSummary)
    }

    /// Shared reading-activity factory so generation (RoadmapBuilder) and the
    /// bundled sample (SeedData) produce identical reading steps.
    static func readingActivity(title: String, summary: String) -> Exercise {
        let cue = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = cue.isEmpty
            ? "Read the section for “\(title)” in your own copy."
            : "Read the section for “\(title)” in your own copy. \(cue)"
        return Exercise(
            kind: .reading,
            prompt: prompt,
            xp: ExerciseKind.reading.baseXP,
            order: 0
        )
    }
}
