import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to unblock a user on the Messenger Platform.
 *
 * @param {Object} args - Arguments for the unblock user request.
 * @param {string} args.pageId - The ID of the Facebook page.
 * @param {string} args.pageScopedId - The ID of the user to unblock.
 * @returns {Promise<Object>} - The result of the unblock user request.
 */
const executeFunction = async (args = {}) => {
  const { pageId, pageScopedId } = args;
  const version = 'v22.0'; // Specify the API version
  const token = getToken();
  const url = `https://graph.facebook.com/${version}/${getPageId(typeof pageId !== "undefined" ? pageId : args.pageId)}/moderate_conversations`;
  
  const body = {
    user_ids: [
      {
        id: pageScopedId
      }
    ],
    actions: ["unblock_user"]
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
    console.error('Error unblocking user:', error);
    return {
      error: `An error occurred while unblocking the user: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for unblocking a user on the Messenger Platform.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'unblock_user',
      description: 'Unblock a user on the Messenger Platform.',
      parameters: {
        type: 'object',
        properties: {
          pageId: {
            type: 'string',
            description: 'The ID of the Facebook page.'
          },
          pageScopedId: {
            type: 'string',
            description: 'The ID of the user to unblock.'
          }
        },
        required: ['pageId', 'pageScopedId']
      }
    }
  }
};

export { apiTool };