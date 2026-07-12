import type { GalleryPhotoRecord, ViewerPhotoCommentRecord } from "../../types";
import type { Dispatch, FormEvent, SetStateAction } from "react";

type GalleryCommentsProps = {
  selectedPhoto: GalleryPhotoRecord;
  commentActionId: string | null;
  commentText: string;
  isSubmittingComment: boolean;
  setCommentText: Dispatch<SetStateAction<string>>;
  editComment: (comment: ViewerPhotoCommentRecord) => Promise<void>;
  deleteComment: (comment: ViewerPhotoCommentRecord) => Promise<void>;
  submitComment: (event: FormEvent<HTMLFormElement>) => Promise<void>;
};

function GalleryComments({
  selectedPhoto,
  commentActionId,
  commentText,
  isSubmittingComment,
  setCommentText,
  editComment,
  deleteComment,
  submitComment,
}: GalleryCommentsProps) {
  return (
    <section className="photo-comments">
      <h2>Comments and edit notes</h2>

      {selectedPhoto.comments.length === 0 ? (
        <p className="no-comments">No comments yet.</p>
      ) : (
        <div className="comment-list">
          {selectedPhoto.comments.map((comment) => (
            <article key={comment.id}>
              <div className="comment-heading">
                <strong>{comment.displayName}</strong>

                {comment.viewerOwned && (
                  <div className="comment-actions">
                    <button
                      type="button"
                      disabled={commentActionId === comment.id}
                      onClick={() => void editComment(comment)}
                    >
                      Edit
                    </button>

                    <button
                      type="button"
                      disabled={commentActionId === comment.id}
                      onClick={() => void deleteComment(comment)}
                    >
                      Delete
                    </button>
                  </div>
                )}
              </div>

              <p>{comment.body}</p>

              {comment.updatedAt !== comment.createdAt && <small>Edited</small>}
            </article>
          ))}
        </div>
      )}

      <form
        className="comment-form"
        onSubmit={(event) => void submitComment(event)}
      >
        <label htmlFor={`comment-${selectedPhoto.id}`}>
          Leave a comment or edit note
        </label>

        <textarea
          id={`comment-${selectedPhoto.id}`}
          value={commentText}
          onChange={(event) => setCommentText(event.target.value)}
          maxLength={1000}
          placeholder="For example: Can you remove the stain from my shirt?"
          disabled={isSubmittingComment}
        />

        <div className="comment-form-footer">
          <span>{commentText.length}/1000</span>

          <button
            type="submit"
            disabled={isSubmittingComment || commentText.trim().length === 0}
          >
            {isSubmittingComment ? "Posting…" : "Post comment"}
          </button>
        </div>
      </form>
    </section>
  );
}

export default GalleryComments;
