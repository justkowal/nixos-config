import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to unban a user on the Messenger Platform.
 *
 * @param {Object} args - Arguments for the unban action.
 * @param {string} args.pageScopedId - The page-scoped ID of the user to unban.
 * @param {string} args.pageId - The ID of the Facebook page.
 * @param {string} args.version - The version of the Messenger API to use.
 * @returns {Promise<Object>} - The result of the unban action.
 */
const executeFunction = async (args = {}) => {
  const { pageScopedId, pageId, version } = args;
  const token = getToken();
  const url = `https://graph.facebook.com/${version}/${getPageId(typeof pageId !== "undefined" ? pageId : args.pageId)}/moderate_conversations`;
  
  const body = {
    user_ids: [{ id: pageScopedId }],
    actions: ["unban_user"]
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
    console.error('Error unbanning user:', error);
    return {
      error: `An error occurred while unbanning the user: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for unbanning a user on the Messenger Platform.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'unban_user',
      description: 'Unban a user on the Messenger Platform.',
      parameters: {
        type: 'object',
        properties: {
          pageScopedId: {
            type: 'string',
            description: 'The page-scoped ID of the user to unban.'
          },
          pageId: {
            type: 'string',
            description: 'The ID of the Facebook page.'
          },
          version: {
            type: 'string',
            description: 'The version of the Messenger API to use.'
          }
        },
        required: ['pageScopedId', 'pageId', 'version']
      }
    }
  }
};

export { apiTool };