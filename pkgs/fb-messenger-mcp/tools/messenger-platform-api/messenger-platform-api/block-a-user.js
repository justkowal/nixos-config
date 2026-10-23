import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to block a user on the Messenger Platform.
 *
 * @param {Object} args - Arguments for blocking a user.
 * @param {string} args.pageId - The ID of the Facebook page.
 * @param {string} args.version - The API version to use.
 * @param {string} args.pageScopedId - The page-scoped ID of the user to block.
 * @returns {Promise<Object>} - The result of the block user request.
 */
const executeFunction = async (args = {}) => {
  const { pageId, version, pageScopedId } = args;
  const token = getToken();
  const url = `https://graph.facebook.com/${version}/${getPageId(typeof pageId !== "undefined" ? pageId : args.pageId)}/moderate_conversations`;
  
  const body = {
    user_ids: [
      { id: pageScopedId }
    ],
    actions: ["block_user"]
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
    console.error('Error blocking user:', error);
    return {
      error: `An error occurred while blocking the user: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for blocking a user on the Messenger Platform.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'block_user',
      description: 'Block a user on the Messenger Platform.',
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
            description: 'The page-scoped ID of the user to block.'
          }
        },
        required: ['pageId', 'version', 'pageScopedId']
      }
    }
  }
};

export { apiTool };