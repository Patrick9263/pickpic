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
  interactionsEnabled: boolean;
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
  interactionsEnabled,
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

                {comment.viewerOwned && interactionsEnabled && (
                  <div className="comment-actions">
                    <button
                      type="button"
                      disabled={commentActionId === comment.id}
                      onClick={() => void editComment(comment)}
                      aria-label="Edit comment"
                      title="Edit comment"
                    >
                      <svg aria-hidden="true" viewBox="0 0 24 24">
                        <path
                          d="M21.17 6.81a2.82 2.82 0 0 0-3.99-3.99L3.84 16.17a2 2 0 0 0-.5.83l-1.32 4.35a.5.5 0 0 0 .62.62l4.35-1.32a2 2 0 0 0 .83-.5zM15 5l4 4"
                          fill="none"
                          stroke="currentColor"
                          strokeLinecap="round"
                          strokeLinejoin="round"
                          strokeWidth="2"
                        />
                      </svg>
                    </button>

                    <button
                      type="button"
                      disabled={commentActionId === comment.id}
                      onClick={() => void deleteComment(comment)}
                      aria-label="Delete comment"
                      title="Delete comment"
                    >
                      <svg aria-hidden="true" viewBox="0 0 24 24">
                        <path
                          d="M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M10 11v6M14 11v6"
                          fill="none"
                          stroke="currentColor"
                          strokeLinecap="round"
                          strokeLinejoin="round"
                          strokeWidth="2"
                        />
                      </svg>
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
      {interactionsEnabled ? (
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
      ) : (
        <div className="comments-closed-message">
          Comments are read-only because this gallery has been closed.
        </div>
      )}
    </section>
  );
}

export default GalleryComments;
