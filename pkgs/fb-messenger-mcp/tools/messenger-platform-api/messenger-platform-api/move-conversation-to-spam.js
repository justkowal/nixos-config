import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to move a conversation to spam on the Messenger Platform.
 *
 * @param {Object} args - Arguments for moving the conversation.
 * @param {string} args.pageId - The ID of the Facebook page.
 * @param {string} args.version - The API version to use.
 * @param {string} args.pageScopedId - The page-scoped ID of the user.
 * @returns {Promise<Object>} - The result of the operation.
 */
const executeFunction = async (args = {}) => {
  const { pageId, version, pageScopedId } = args;
  const token = getToken();
  const url = `https://graph.facebook.com/${version}/${getPageId(typeof pageId !== "undefined" ? pageId : args.pageId)}/moderate_conversations`;
  
  const body = {
    user_ids: [
      {
        id: pageScopedId
      }
    ],
    actions: ["move_to_spam"]
  };

  try {
    // Set up headers for the request
    const headers = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`
    };

    // Perform the fetch request
    const response = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(body)
    });

    // Check if the response was successful
    if (!response.ok) {
      const errorData = await response.json();
      throw new Error(JSON.stringify(errorData));
    }

    // Parse and return the response data
    const data = await response.json();
    return data;
  } catch (error) {
    console.error('Error moving conversation to spam:', error);
    return {
      error: `An error occurred while moving the conversation to spam: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for moving a conversation to spam on the Messenger Platform.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'move_conversation_to_spam',
      description: 'Move a conversation to spam on the Messenger Platform.',
      parameters: {
        type: 'object',
        properties: {
          pageId: {
            type: 'string',
            description: 'The ID of the Facebook page.'
          },
          version: {
            type: 'string',
            description: 'The API version to use.'
          },
          pageScopedId: {
            type: 'string',
            description: 'The page-scoped ID of the user.'
          }
        },
        required: ['pageId', 'version', 'pageScopedId']
      }
    }
  }
};

export { apiTool };