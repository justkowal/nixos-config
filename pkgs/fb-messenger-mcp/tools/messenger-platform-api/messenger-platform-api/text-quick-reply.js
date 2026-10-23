import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to send a text quick reply message via the Messenger Platform API.
 *
 * @param {Object} args - Arguments for sending the quick reply.
 * @param {string} args.pageScopedId - The page-scoped ID of the recipient.
 * @param {string} [args.version='v22.0'] - The version of the Messenger API to use.
 * @returns {Promise<Object>} - The result of the message sending operation.
 */
const executeFunction = async (args = {}) => {
  const { pageScopedId, version = 'v22.0' } = args;
  const baseUrl = 'https://graph.facebook.com';
  const token = getToken();
  const url = `${baseUrl}/${version}/${getPageId(args.pageId)}/messages`;
  
  const body = {
    recipient: {
      id: pageScopedId
    },
    messaging_type: "RESPONSE",
    message: {
      text: "Pick a color:",
      quick_replies: [
        {
          content_type: "text",
          title: "Red",
          payload: "{POSTBACK_PAYLOAD}",
          image_url: "http://example.com/img/red.png"
        },
        {
          content_type: "text",
          title: "Green",
          payload: "{POSTBACK_PAYLOAD}",
          image_url: "http://example.com/img/green.png"
        }
      ]
    }
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
    console.error('Error sending quick reply:', error);
    return {
      error: `An error occurred while sending the quick reply: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for sending a text quick reply via the Messenger Platform API.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'send_text_quick_reply',
      description: 'Send a text quick reply message via the Messenger Platform API.',
      parameters: {
        type: 'object',
        properties: {
          pageScopedId: {
            type: 'string',
            description: 'The page-scoped ID of the recipient.'
          },
          version: {
            type: 'string',
            description: 'The version of the Messenger API to use.'
          }
        },
        required: ['pageScopedId']
      }
    }
  }
};

export { apiTool };