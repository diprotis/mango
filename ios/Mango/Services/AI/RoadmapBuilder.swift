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
                for (eIndex, exerciseDTO) in lessonDTO.exercises.enumerated() {
                    let kind = ExerciseKind(rawValue: exerciseDTO.kind) ?? .reflection
                    let exercise = Exercise(
                        kind: kind,
                        prompt: exerciseDTO.prompt,
                        options: exerciseDTO.options ?? [],
                        answerIndex: exerciseDTO.answerIndex,
                        xp: exerciseDTO.xp > 0 ? exerciseDTO.xp : kind.baseXP,
                        order: eIndex
                    )
                    lesson.exercises.append(exercise)
                }
                milestone.lessons.append(lesson)
            }
            roadmap.milestones.append(milestone)
        }
        context.insert(roadmap)
    }
}
